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
)

const (
	defaultPort = 1000
	bufSize     = 32768 // 32KB buffer, good balance for latency
	connectTO   = 5 * time.Second
	idleTO      = 300 * time.Second
	writeTO     = 30 * time.Second
	acceptTO    = 100 * time.Millisecond
)

// Route 静态路由
type Route struct {
	Path    string
	Backend string
}

// DynamicRoute 动态路由
type DynamicRoute struct {
	Pattern string
	Backend string
	Regex   *regexp.Regexp
	Extract int
	IsRange bool
	MinPort int
	MaxPort int
	// 预编译的替换正则
	portRe   *regexp.Regexp
	wildRe   *regexp.Regexp
}

var (
	configPath string
	listenPort int
	routes     []Route
	dynRoutes  []DynamicRoute
	shutdown   atomic.Bool
	
	// 预编译正则（避免每次请求都编译）
	portReplaceRe = regexp.MustCompile(`<port>`)
	wildReplaceRe = regexp.MustCompile(`\*`)
	
	// Buffer pool
	bufPool = sync.Pool{
		New: func() interface{} {
			buf := make([]byte, bufSize)
			return &buf
		},
	}
)

func loadConfig() error {
	routes = nil
	dynRoutes = nil
	listenPort = defaultPort

	f, err := os.Open(configPath)
	if err != nil {
		return fmt.Errorf("open config: %w", err)
	}
	defer f.Close()

	scanner := bufio.NewScanner(f)
	inRouters := false

	for scanner.Scan() {
		line := bytes.TrimSpace(scanner.Bytes())
		if len(line) == 0 || bytes.HasPrefix(line, []byte("//")) || bytes.HasPrefix(line, []byte("#")) {
			continue
		}

		if bytes.Equal(line, []byte("[routers]")) {
			inRouters = true
			continue
		}
		if bytes.HasPrefix(line, []byte("[")) && bytes.HasSuffix(line, []byte("]")) {
			inRouters = false
			continue
		}

		if !inRouters && bytes.HasPrefix(line, []byte("listen_port")) {
			parts := bytes.Fields(line)
			if len(parts) >= 3 && bytes.Equal(parts[1], []byte("=")) {
				fmt.Sscanf(string(parts[2]), "%d", &listenPort)
			}
			continue
		}

		if inRouters && bytes.Contains(line, []byte("=")) {
			parts := bytes.Fields(line)
			if len(parts) >= 3 && bytes.Equal(parts[1], []byte("=")) {
				path := string(bytes.Trim(parts[0], `"`))
				backend := string(bytes.Trim(parts[2], `"`))
				if path != "" && backend != "" {
					if bytes.Contains([]byte(path), []byte("*")) || isDynamicPattern(path) {
						dyn := DynamicRoute{
							Pattern: path,
							Backend: backend,
						}
						if err := dyn.compile(); err != nil {
							log.Printf("  Warning: Invalid dynamic pattern %s: %v", path, err)
							continue
						}
						dynRoutes = append(dynRoutes, dyn)
					} else {
						routes = append(routes, Route{Path: path, Backend: backend})
					}
				}
			}
			continue
		}

		parts := bytes.Fields(line)
		if len(parts) >= 2 && !inRouters {
			routes = append(routes, Route{Path: string(parts[0]), Backend: string(parts[1])})
		}
	}
	return scanner.Err()
}

func isDynamicPattern(path string) bool {
	if bytes.Contains([]byte(path), []byte("*")) {
		return true
	}
	if bytes.Contains([]byte(path), []byte("-")) {
		parts := bytes.Split([]byte(path), []byte("-"))
		if len(parts) >= 3 {
			last := string(parts[len(parts)-1])
			if _, err := strconv.Atoi(last); err == nil {
				return true
			}
		}
	}
	return false
}

func (d *DynamicRoute) compile() error {
	pattern := d.Pattern

	// 检查范围模式
	if bytes.Contains([]byte(pattern), []byte("-")) {
		parts := bytes.Split([]byte(pattern), []byte("-"))
		if len(parts) >= 3 {
			last := string(parts[len(parts)-1])
			secondLast := string(parts[len(parts)-2])
			if _, err1 := strconv.Atoi(last); err1 == nil {
				if _, err2 := strconv.Atoi(secondLast); err2 == nil {
					prefix := pattern[:len(pattern)-len(secondLast)-1-len(last)]
					pattern = regexp.QuoteMeta(prefix) + `(\d+)`
					d.IsRange = true
					d.MinPort, _ = strconv.Atoi(secondLast)
					d.MaxPort, _ = strconv.Atoi(last)
				}
			}
		}
	}

	if !d.IsRange {
		pattern = regexp.QuoteMeta(pattern)
		pattern = regexp.MustCompile(`\\\?\\\*`).ReplaceAllString(pattern, `(\d+)`)
	}

	pattern = "^" + pattern + "$"

	re, err := regexp.Compile(pattern)
	if err != nil {
		return err
	}

	d.Regex = re
	d.Extract = 1
	return nil
}

func (d *DynamicRoute) matchDynamic(path string) (string, bool) {
	if d.Regex == nil {
		return "", false
	}

	matches := d.Regex.FindStringSubmatch(path)
	if len(matches) < 2 {
		return "", false
	}

	portStr := matches[d.Extract]
	port, err := strconv.Atoi(portStr)
	if err != nil {
		return "", false
	}

	// 范围检查（使用预存储的值，避免重复解析）
	if d.IsRange {
		if port < d.MinPort || port > d.MaxPort {
			return "", false
		}
	} else if bytes.Contains([]byte(d.Pattern), []byte("-")) {
		// 兼容旧逻辑
		parts := bytes.Split([]byte(d.Pattern), []byte("-"))
		if len(parts) >= 3 {
			last := string(parts[len(parts)-1])
			secondLast := string(parts[len(parts)-2])
			if minPort, err1 := strconv.Atoi(secondLast); err1 == nil {
				if maxPort, err2 := strconv.Atoi(last); err2 == nil {
					if port < minPort || port > maxPort {
						return "", false
					}
				}
			}
		}
	}

	// 自身端口保护
	if port == listenPort {
		return "", false
	}

	// 使用预编译的正则替换
	backend := d.Backend
	backend = portReplaceRe.ReplaceAllString(backend, portStr)
	backend = wildReplaceRe.ReplaceAllString(backend, portStr)

	return backend, true
}

func findRoute(path string) (string, bool) {
	// 静态路由
	for i := range routes {
		if bytes.HasPrefix([]byte(path), []byte(routes[i].Path)) {
			return routes[i].Backend, true
		}
	}

	// 范围匹配优先
	for i := range dynRoutes {
		if dynRoutes[i].IsRange {
			if backend, ok := dynRoutes[i].matchDynamic(path); ok {
				return backend, true
			}
		}
	}

	// 通配符匹配
	for i := range dynRoutes {
		if !dynRoutes[i].IsRange {
			if backend, ok := dynRoutes[i].matchDynamic(path); ok {
				return backend, true
			}
		}
	}

	return "", false
}

func copyConn(src, dst net.Conn, name string, done chan<- error) {
	// 从 pool 获取 buffer
	bufPtr := bufPool.Get().(*[]byte)
	buf := *bufPtr
	defer bufPool.Put(bufPtr)

	for {
		src.SetReadDeadline(time.Now().Add(idleTO))
		n, err := src.Read(buf)
		if n > 0 {
			dst.SetWriteDeadline(time.Now().Add(writeTO))
			if _, werr := dst.Write(buf[:n]); werr != nil {
				done <- fmt.Errorf("%s write: %w", name, werr)
				return
			}
		}
		if err != nil {
			if err == io.EOF {
				done <- nil
			} else {
				done <- fmt.Errorf("%s read: %w", name, err)
			}
			return
		}
	}
}

func handle(conn net.Conn) {
	// Enable TCP keepalive on client connection (toward ESA/CDN)
	if tcpConn, ok := conn.(*net.TCPConn); ok {
		tcpConn.SetKeepAlive(true)
		tcpConn.SetKeepAlivePeriod(30 * time.Second)
	}

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
		// 静默丢弃未知路径，避免日志噪音
		return
	}

	target, err := net.DialTimeout("tcp", backend, connectTO)
	if err != nil {
		// 静默处理后端错误
		return
	}
	defer target.Close()

	// Enable TCP keepalive on backend connection
	if tcpTarget, ok := target.(*net.TCPConn); ok {
		tcpTarget.SetKeepAlive(true)
		tcpTarget.SetKeepAlivePeriod(30 * time.Second)
	}

	log.Printf("[breath] Backend connected: %s -> %s", path, backend)

	if _, err := target.Write(header.Bytes()); err != nil {
		return
	}

	c2b := make(chan error, 1)
	b2c := make(chan error, 1)

	go copyConn(conn, target, "C->B", c2b)
	go copyConn(target, conn, "B->C", b2c)

	var wg sync.WaitGroup
	wg.Add(2)
	go func() { c2b <- <-c2b; wg.Done() }()
	go func() { b2c <- <-b2c; wg.Done() }()
	wg.Wait()
}

func main() {
	log.SetFlags(log.Ltime | log.Lmsgprefix)
	log.SetPrefix("[router] ")

	// 解析命令行参数
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

	// 检查环境变量
	if envPort := os.Getenv("ESA_PORT"); envPort != "" {
		if port, err := strconv.Atoi(envPort); err == nil && port > 0 {
			listenPort = port
		}
	}

	// 加载配置文件（如果存在）
	args := os.Args[1:]
	if len(args) == 0 {
		configPath = "/etc/esa-router/config.toml"
	} else {
		configPath = args[0]
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
		log.Printf("  %s -> %s (static)", r.Path, r.Backend)
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
				for _, r := range routes {
					log.Printf("  %s -> %s (static)", r.Path, r.Backend)
				}
				for _, r := range dynRoutes {
					log.Printf("  %s -> %s (dynamic)", r.Pattern, r.Backend)
				}
				newAddr := fmt.Sprintf(":%d", listenPort)
				if newAddr != addr {
					log.Printf("Port changed: %s -> %s", addr, newAddr)
					ln.Close()
					ln, err = net.Listen("tcp", newAddr)
					if err != nil {
						log.Fatalf("Listen %s: %v", newAddr, err)
					}
					tcpLn = ln.(*net.TCPListener)
					addr = newAddr
					log.Printf("Listening on %s", addr)
				}
				continue
			}
			log.Println("Shutting down...")
			shutdown.Store(true)
			ln.Close()
			return
		}
	}()

	for {
		tcpLn.SetDeadline(time.Now().Add(acceptTO))
		conn, err := ln.Accept()
		if err != nil {
			if shutdown.Load() {
				log.Println("Shutdown complete")
				return
			}
			continue
		}
		go handle(conn)
	}
}
