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
	"syscall"
	"time"
)

const connectTO = 10 * time.Second

type Route struct {
	Pattern string
	Backend string
	Regex   *regexp.Regexp
	Priority int
}

var (
	routes      []Route
	dynRoutes   []Route
	listenPort  int
)

func loadConfig() error {
	configPath := "/etc/esa-router/config.toml"
	if len(os.Args) > 1 {
		configPath = os.Args[1]
	}

	data, err := os.ReadFile(configPath)
	if err != nil {
		return fmt.Errorf("read config: %w", err)
	}

	content := string(data)
	listenPort = 7826
	inRouters := false

	for _, line := range strings.Split(content, "\n") {
		line = strings.TrimSpace(line)
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}

		if strings.HasPrefix(line, "listen_port") {
			parts := strings.SplitN(line, "=", 2)
			if len(parts) == 2 {
				port, err := strconv.Atoi(strings.TrimSpace(parts[1]))
				if err == nil {
					listenPort = port
				}
			}
			continue
		}

		if line == "[routers]" {
			inRouters = true
			continue
		}

		if strings.HasPrefix(line, "[") && inRouters {
			inRouters = false
			continue
		}

		if inRouters && strings.Contains(line, "=") {
			parts := strings.SplitN(line, "=", 2)
			if len(parts) == 2 {
				path := strings.TrimSpace(strings.Trim(parts[0], `"`))
				backend := strings.TrimSpace(strings.Trim(parts[1], `"`))

				route := Route{Pattern: path, Backend: backend, Priority: 2}

				if strings.Contains(path, "*") {
					route.Priority = 2
				} else if strings.Count(path, "-") >= 2 {
					route.Priority = 1
					re := regexp.MustCompile(`^/node-(\d+)-(\d+)$`)
					if m := re.FindStringSubmatch(path); m != nil {
						route.Regex = re
					}
				} else if !strings.Contains(path, "*") {
					route.Priority = 0
					re := regexp.MustCompile("^" + regexp.QuoteMeta(path) + "$")
					route.Regex = re
				}

				if route.Regex != nil {
					routes = append(routes, route)
				} else {
					dynRoutes = append(dynRoutes, route)
				}
			}
		}
	}

	return nil
}

func findRoute(path string) (string, bool) {
	trimmed := strings.TrimPrefix(path, "/")

	for _, r := range routes {
		if r.Priority == 0 {
			if r.Regex.MatchString(path) {
				return r.Backend, true
			}
		}
	}

	for _, r := range routes {
		if r.Priority == 1 && r.Regex != nil {
			if m := r.Regex.FindStringSubmatch(path); m != nil {
				port, _ := strconv.Atoi(m[1])
				if port >= 20001 && port <= 30000 {
					return fmt.Sprintf("127.0.0.1:%s", m[1]), true
				}
			}
		}
	}

	for _, r := range dynRoutes {
		if strings.Contains(r.Pattern, "*") {
			return fmt.Sprintf("127.0.0.1:%s", trimmed), true
		}
	}

	return "", false
}

func copyConn(dst, src net.Conn, dir string, errChan chan<- error) {
	_, err := io.Copy(dst, src)
	errChan <- err
}

func handle(conn net.Conn) {
	// Enable TCP keepalive on client connection (toward ESA/CDN)
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

	backend, ok := findRoute(path)
	if !ok {
		return
	}

	// 向 ESA/CDN 方向发送 Keepalive 探测，防止空闲断开
	log.Printf("[breath] 向 ESA 探测: %s <- :1000 (30秒间隔)", remoteAddr)

	target, err := net.DialTimeout("tcp", backend, connectTO)
	if err != nil {
		return
	}
	defer target.Close()

	if _, err := target.Write(header.Bytes()); err != nil {
		return
	}

	c2b := make(chan error, 1)
	b2c := make(chan error, 1)

	go copyConn(target, conn, "C->B", c2b)
	go copyConn(conn, target, "B->C", b2c)

	var wg sync.WaitGroup
	wg.Add(2)
	go func() { c2b <- <-c2b; wg.Done() }()
	go func() { b2c <- <-b2c; wg.Done() }()
	wg.Wait()
}

func main() {
	log.SetFlags(log.Ltime | log.Lmsgprefix)
	log.SetPrefix("[router] ")

	for i := 0; i < len(os.Args); i++ {
		arg := os.Args[i]
		if arg == "--port" && i+1 < len(os.Args) {
			port, err := strconv.Atoi(os.Args[i+1])
			if err == nil && port > 0 {
				listenPort = port
				i++
			}
		} else if strings.HasPrefix(arg, "--port=") {
			port, err := strconv.Atoi(strings.TrimPrefix(arg, "--port="))
			if err == nil && port > 0 {
				listenPort = port
			}
		}
	}

	if envPort := os.Getenv("ESA_PORT"); envPort != "" {
		if port, err := strconv.Atoi(envPort); err == nil && port > 0 {
			listenPort = port
		}
	}

	configPath := "/etc/esa-router/config.toml"
	if len(os.Args) > 1 {
		configPath = os.Args[1]
	}

	if err := loadConfig(); err != nil {
		log.Fatalf("Load config failed: %v", err)
	}

	log.Printf("Loaded %d static routes, %d dynamic routes", len(routes), len(dynRoutes))

	addr := fmt.Sprintf(":%d", listenPort)
	lc := net.ListenConfig{
		KeepAlive: 30 * time.Second,
	}
	ln, err := lc.Listen(context.Background(), "tcp", addr)
	if err != nil {
		log.Fatalf("Listen: %v", err)
	}
	log.Printf("Listening on %s", addr)

	for _, r := range routes {
		log.Printf("  %s -> %s (static)", r.Pattern, r.Backend)
	}
	for _, r := range dynRoutes {
		log.Printf("  %s -> %s (dynamic)", r.Pattern, r.Backend)
	}

	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM, syscall.SIGHUP)

	tcpLn, ok := ln.(*net.TCPListener)
	if !ok {
		log.Fatal("Listener must be TCP")
	}

	go func() {
		for sig := range sigCh {
			if sig == syscall.SIGHUP {
				log.Println("Reloading config...")
				if err := loadConfig(); err != nil {
					log.Printf("Reload failed: %v", err)
					continue
				}
				log.Printf("Reloaded %d static, %d dynamic routes", len(routes), len(dynRoutes))
			}
		}
	}()

	log.Println("Ready")

	for {
		conn, err := tcpLn.AcceptTCP()
		if err != nil {
			continue
		}
		conn.SetKeepAlive(true)
		conn.SetKeepAlivePeriod(30 * time.Second)
		go handle(conn)
	}
}
