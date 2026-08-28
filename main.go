package main

import (
	"bufio"
	"bytes"
	"context"
	"fmt"
	"io"
	"log"
	"net"
	"os"
	"os/signal"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"

	"github.com/pelletier/go-toml/v2"
)

const (
	connectTO = 10 * time.Second
)

type RouteType int

const (
	RouteTypeStatic RouteType = iota
	RouteTypeRange
	RouteTypeWildcard
)

type Route struct {
	Pattern  string
	Backend  string
	Type     RouteType
	Regex    *regexp.Regexp
	MinPort  int
	MaxPort  int
	Priority int
}

type Config struct {
	ListenPort int         `toml:"listen_port"`
	Routers    []RouteConfig `toml:"routers"`
}

type RouteConfig struct {
	Path    string `toml:"path"`
	Backend string `toml:"backend"`
	MinPort int    `toml:"min_port,omitempty"`
	MaxPort int    `toml:"max_port,omitempty"`
}

type Router struct {
	routes     []Route
	listenPort int
	mu         sync.RWMutex
	activeConn int64
	shutdown   atomic.Bool
	wg         sync.WaitGroup
}

func NewRouter() *Router {
	return &Router{
		routes: make([]Route, 0),
	}
}

func (r *Router) LoadConfig(configPath string) error {
	data, err := os.ReadFile(configPath)
	if err != nil {
		return fmt.Errorf("read config: %w", err)
	}

	var cfg Config
	if err := toml.Unmarshal(data, &cfg); err != nil {
		return fmt.Errorf("parse config: %w", err)
	}

	r.mu.Lock()
	defer r.mu.Unlock()

	r.listenPort = cfg.ListenPort
	if r.listenPort <= 0 {
		r.listenPort = 7826
	}

	r.routes = make([]Route, 0, len(cfg.Routers))
	for _, router := range cfg.Routers {
		route, err := r.parseRouter(router)
		if err != nil {
			log.Printf("Warning: skip invalid router %s: %v", router.Path, err)
			continue
		}
		r.routes = append(r.routes, route)
	}

	// Sort by priority: static(0) > range(1) > wildcard(2)
	// Same priority: longer pattern first
	for i := 0; i < len(r.routes); i++ {
		for j := i + 1; j < len(r.routes); j++ {
			if r.routes[i].Priority > r.routes[j].Priority ||
				(r.routes[i].Priority == r.routes[j].Priority && len(r.routes[i].Pattern) < len(r.routes[j].Pattern)) {
				r.routes[i], r.routes[j] = r.routes[j], r.routes[i]
			}
		}
	}

	return nil
}

func (r *Router) parseRouter(router RouteConfig) (Route, error) {
	path := strings.TrimSpace(router.Path)
	backend := strings.TrimSpace(router.Backend)

	if path == "" || backend == "" {
		return Route{}, fmt.Errorf("empty path or backend")
	}

	route := Route{
		Pattern: path,
		Backend: backend,
	}

	// Check for range by min_port/max_port first
	if router.MinPort > 0 || router.MaxPort > 0 {
		route.Type = RouteTypeRange
		route.Priority = 1
		if router.MinPort > 0 {
			route.MinPort = router.MinPort
		} else {
			route.MinPort = 20001
		}
		if router.MaxPort > 0 {
			route.MaxPort = router.MaxPort
		} else {
			route.MaxPort = 30000
		}
		// Compile regex for port extraction from path like /node-25000
		route.Regex = regexp.MustCompile(`^/node-(\d+)$`)
	} else if strings.Contains(path, "*") {
		route.Type = RouteTypeWildcard
		route.Priority = 2
	} else {
		route.Type = RouteTypeStatic
		route.Priority = 0
		route.Regex = regexp.MustCompile("^" + regexp.QuoteMeta(path) + "$")
	}

	return route, nil
}

func (r *Router) FindRoute(path string) (string, bool) {
	r.mu.RLock()
	defer r.mu.RUnlock()

	trimmed := strings.TrimPrefix(path, "/")

	for _, route := range r.routes {
		switch route.Type {
		case RouteTypeStatic:
			if route.Regex.MatchString(path) {
				return route.Backend, true
			}
		case RouteTypeRange:
			if m := route.Regex.FindStringSubmatch(path); m != nil {
				port, err := strconv.Atoi(m[1])
				if err == nil && port >= route.MinPort && port <= route.MaxPort {
					return fmt.Sprintf("127.0.0.1:%d", port), true
				}
			}
		case RouteTypeWildcard:
			if strings.Contains(route.Pattern, "*") {
				// Extract port from path (e.g., /node-30925 -> 30925)
				port := strings.TrimPrefix(trimmed, "node-")
				// Replace <port> in backend template
				backend := strings.Replace(route.Backend, "<port>", port, 1)
				return backend, true
			}
		}
	}
	return "", false
}

func (r *Router) GetListenPort() int {
	r.mu.RLock()
	defer r.mu.RUnlock()
	return r.listenPort
}

func (r *Router) GetRoutesInfo() ([]Route, int) {
	r.mu.RLock()
	defer r.mu.RUnlock()
	routesCopy := make([]Route, len(r.routes))
	copy(routesCopy, r.routes)
	return routesCopy, r.listenPort
}

func copyConn(dst, src net.Conn, errChan chan<- error) {
	_, err := io.Copy(dst, src)
	errChan <- err
}

type ConnectionHandler struct {
	router *Router
	wg     sync.WaitGroup
}

func NewConnectionHandler(router *Router) *ConnectionHandler {
	return &ConnectionHandler{router: router}
}

func (h *ConnectionHandler) Handle(conn net.Conn) {
	if tcpConn, ok := conn.(*net.TCPConn); ok {
		tcpConn.SetKeepAlive(true)
		tcpConn.SetKeepAlivePeriod(30 * time.Second)
	}

	localAddr := conn.LocalAddr().String()
	remoteAddr := conn.RemoteAddr().String()
	log.Printf("[breath] Client connected: %s <- %s", localAddr, remoteAddr)

	defer conn.Close()

	reader := bufio.NewReader(conn)
	var header bytes.Buffer

	for {
		line, err := reader.ReadString('\n')
		if err != nil {
			return
		}
		header.WriteString(line)
		if line == "\r\n" || line == "\n" {
			break
		}
	}

	firstLine := header.Bytes()
	idx := bytes.Index(firstLine, []byte("\r\n"))
	if idx < 0 {
		return
	}
	fields := bytes.Fields(firstLine[:idx])
	if len(fields) < 2 {
		return
	}
	path := string(fields[1])
	pathBytes := []byte(path)
	if q := bytes.Index(pathBytes, []byte("?")); q >= 0 {
		path = string(pathBytes[:q])
	}

	backend, ok := h.router.FindRoute(path)
	if !ok {
		return
	}

	log.Printf("[breath] 向 ESA 探测: %s <- :%d (30秒间隔)", remoteAddr, h.router.GetListenPort())

	target, err := net.DialTimeout("tcp", backend, connectTO)
	if err != nil {
		log.Printf("Dial failed: %v", err)
		return
	}
	defer target.Close()

	if _, err := target.Write(header.Bytes()); err != nil {
		return
	}

	errChan := make(chan error, 2)
	go copyConn(target, conn, errChan)
	go copyConn(conn, target, errChan)

	h.wg.Add(2)
	go func() { errChan <- <-errChan; h.wg.Done() }()
	go func() { errChan <- <-errChan; h.wg.Done() }()
	h.wg.Wait()
}

func main() {
	log.SetFlags(log.Ltime | log.Lmsgprefix)
	log.SetPrefix("[router] ")

	configPath := "/etc/esa-router/config.toml"
	if len(os.Args) > 1 && !strings.HasPrefix(os.Args[1], "--") {
		configPath = os.Args[1]
	}

	router := NewRouter()
	if err := router.LoadConfig(configPath); err != nil {
		log.Fatalf("Load config failed: %v", err)
	}

	// Parse CLI args
	listenPort := router.GetListenPort()
	for i := 0; i < len(os.Args); i++ {
		arg := os.Args[i]
		if arg == "--port" && i+1 < len(os.Args) {
			if port, err := strconv.Atoi(os.Args[i+1]); err == nil && port > 0 {
				listenPort = port
				i++
			}
		} else if strings.HasPrefix(arg, "--port=") {
			if port, err := strconv.Atoi(strings.TrimPrefix(arg, "--port=")); err == nil && port > 0 {
				listenPort = port
			}
		}
	}

	if envPort := os.Getenv("ESA_PORT"); envPort != "" {
		if port, err := strconv.Atoi(envPort); err == nil && port > 0 {
			listenPort = port
		}
	}

	routes, _ := router.GetRoutesInfo()
	log.Printf("Loaded %d routes", len(routes))
	for _, r := range routes {
		switch r.Type {
		case 0:
			log.Printf("  %s -> %s (static)", r.Pattern, r.Backend)
		case 1:
			log.Printf("  %s -> %s (range %d-%d)", r.Pattern, r.Backend, r.MinPort, r.MaxPort)
		case 2:
			log.Printf("  %s -> %s (wildcard)", r.Pattern, r.Backend)
		}
	}

	addr := fmt.Sprintf(":%d", listenPort)
	lc := net.ListenConfig{
		KeepAlive: 30 * time.Second,
	}
	ln, err := lc.Listen(context.Background(), "tcp", addr)
	if err != nil {
		log.Fatalf("Listen: %v", err)
	}
	log.Printf("Listening on %s", addr)

	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM, syscall.SIGHUP)

	tcpLn, ok := ln.(*net.TCPListener)
	if !ok {
		log.Fatal("Listener must be TCP")
	}

	handler := NewConnectionHandler(router)

	// Shutdown handling
	go func() {
		for sig := range sigCh {
			switch sig {
			case syscall.SIGHUP:
				log.Println("Reloading config...")
				if err := router.LoadConfig(configPath); err != nil {
					log.Printf("Reload failed: %v", err)
				} else {
					log.Println("Config reloaded")
				}
			case syscall.SIGINT, syscall.SIGTERM:
				log.Println("Shutting down...")
				router.shutdown.Store(true)
				tcpLn.Close()
				// Wait for active connections
				handler.wg.Wait()
				log.Println("Shutdown complete")
				os.Exit(0)
			}
		}
	}()

	log.Println("Ready")

	for {
		conn, err := tcpLn.AcceptTCP()
		if err != nil {
			if router.shutdown.Load() {
				return
			}
			continue
		}
		// Keepalive is set via ListenConfig (handled at TCP layer)
		// handler.Handle will also set it explicitly as a safety net
		go handler.Handle(conn)
	}
}