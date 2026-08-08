package main

import (
	"bufio"
	"bytes"
	"fmt"
	"io"
	"log"
	"net"
	"os"
	"os/signal"
	"regexp"
	"strconv"
	"sync"
	"sync/atomic"
	"syscall"
	"time"
)

const (
	defaultPort = 1000
	bufSize     = 131072
	connectTO   = 10 * time.Second
	idleTO      = 300 * time.Second
	writeTO     = 30 * time.Second
	acceptTO    = 100 * time.Millisecond
)

// Route 静态路由
type Route struct {
	Path    string
	Backend string
}

// DynamicRoute 动态路由 (支持端口提取)
type DynamicRoute struct {
	Pattern  string      // 例如: /node-*
	Backend  string      // 例如: 127.0.0.1:<port>
	Regex    *regexp.Regexp
	Extract  int         // 捕获组索引
}

var (
	configPath string
	listenPort int
	routes     []Route
	dynRoutes  []DynamicRoute
	shutdown   atomic.Bool
)

// 动态端口正则: 匹配 /node-2001, /ws-3000 等
var portExtractRegex = regexp.MustCompile(`([a-zA-Z_-]+)(\d+)`)

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

		// 检测 [routers] 节
		if bytes.Equal(line, []byte("[routers]")) {
			inRouters = true
			continue
		}
		// 检测到新节则退出
		if bytes.HasPrefix(line, []byte("[")) && bytes.HasSuffix(line, []byte("]")) {
			inRouters = false
			continue
		}

		// 解析 listen_port = 1000
		if !inRouters && bytes.HasPrefix(line, []byte("listen_port")) {
			parts := bytes.Fields(line)
			if len(parts) >= 3 && bytes.Equal(parts[1], []byte("=")) {
				fmt.Sscanf(string(parts[2]), "%d", &listenPort)
			}
			continue
		}

		// 解析 listen = ":1000" (旧格式)
		if !inRouters && bytes.HasPrefix(line, []byte("listen")) {
			parts := bytes.Fields(line)
			if len(parts) >= 3 && bytes.Equal(parts[1], []byte("=")) {
				addr := string(bytes.TrimSpace(parts[2]))
				addr = string(bytes.Trim([]byte(addr), `"'`))
				if len(addr) > 0 && addr[0] == ':' {
					fmt.Sscanf(addr[1:], "%d", &listenPort)
				}
			}
			continue
		}

		// 解析路由
		if inRouters && bytes.Contains(line, []byte("=")) {
			parts := bytes.Fields(line)
			if len(parts) >= 3 && bytes.Equal(parts[1], []byte("=")) {
				path := string(bytes.Trim(parts[0], `"`))
				backend := string(bytes.Trim(parts[2], `"`))
				if path != "" && backend != "" {
					// 检测是否为动态路由 (包含 * 或 -数字-数字 模式)
					if bytes.Contains([]byte(path), []byte("*")) || isDynamicPattern(path) {
						// 动态路由
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
						// 静态路由
						routes = append(routes, Route{Path: path, Backend: backend})
					}
				}
			}
			continue
		}

		// 解析路由 (旧格式: path backend)
		parts := bytes.Fields(line)
		if len(parts) >= 2 && !inRouters {
			routes = append(routes, Route{Path: string(parts[0]), Backend: string(parts[1])})
		}
	}
	return scanner.Err()
}

// isDynamicPattern 检测是否为动态路由模式
func isDynamicPattern(path string) bool {
	// 检查是否包含 *
	if bytes.Contains([]byte(path), []byte("*")) {
		return true
	}
	// 检查是否包含 -数字-数字 范围模式
	if bytes.Contains([]byte(path), []byte("-")) {
		// 例如: /node-2001-3000
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

// compile 编译动态路由的正则
func (d *DynamicRoute) compile() error {
	// 转换模式为正则
	// /node-* → ^/node-(\d+)$
	// /node-2001-3000 → ^/node-(\d+)$ (范围检查在匹配时处理)
	
	pattern := d.Pattern
	// 转义特殊字符
	pattern = regexp.QuoteMeta(pattern)
	// 将 * 替换为捕获组
	pattern = regexp.MustCompile(`\\?\\\*`).ReplaceAllString(pattern, `(\d+)`)
	// 添加锚点
	pattern = "^" + pattern + "$"
	
	re, err := regexp.Compile(pattern)
	if err != nil {
		return err
	}
	
	d.Regex = re
	d.Extract = 1 // 第一个捕获组是端口
	return nil
}

// matchDynamic 尝试匹配动态路由并返回后端地址
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
	
	// 检查范围 - 提取 min 和 max
	if bytes.Contains([]byte(d.Pattern), []byte("-")) {
		parts := bytes.Split([]byte(d.Pattern), []byte("-"))
		if len(parts) >= 3 {
			// 提取最后两个数字部分 (例如 /node-2001-3000 的 2001 和 3000)
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
	
	// 替换后端中的 <port> 或 * 为实际端口
	backend := d.Backend
	backend = regexp.MustCompile(`<port>`).ReplaceAllString(backend, portStr)
	backend = regexp.MustCompile(`\*`).ReplaceAllString(backend, portStr)
	
	return backend, true
}

func findRoute(path string) (string, bool) {
	// 先尝试静态路由
	for i := range routes {
		if bytes.HasPrefix([]byte(path), []byte(routes[i].Path)) {
			return routes[i].Backend, true
		}
	}
	
	// 再尝试动态路由
	for i := range dynRoutes {
		if backend, ok := dynRoutes[i].matchDynamic(path); ok {
			return backend, true
		}
	}
	
	return "", false
}

func copyConn(src, dst net.Conn, name string, done chan<- error) {
	buf := make([]byte, bufSize)
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
		log.Printf("Unknown path: %s", path)
		return
	}

	log.Printf("%s -> %s", path, backend)

	target, err := net.DialTimeout("tcp", backend, connectTO)
	if err != nil {
		log.Printf("Backend error: %v", err)
		return
	}
	defer target.Close()

	if _, err := target.Write(header.Bytes()); err != nil {
		log.Printf("Header write error: %v", err)
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

	log.Printf("Done: C->B=%v, B->C=%v", <-c2b, <-b2c)
}

func main() {
	log.SetFlags(log.Ltime | log.Lmsgprefix)
	log.SetPrefix("[router] ")

	args := os.Args[1:]
	if len(args) == 0 {
		configPath = "/etc/esa-router/config.toml"
	} else {
		configPath = args[0]
	}

	// 初始加载
	if err := loadConfig(); err != nil {
		log.Fatalf("Load config failed: %v", err)
	}

	log.Printf("Loaded %d static routes, %d dynamic routes from %s", len(routes), len(dynRoutes), configPath)

	// 启动监听
	addr := fmt.Sprintf(":%d", listenPort)
	ln, err := net.Listen("tcp", addr)
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

	// 启动信号处理
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
				// 检查端口是否变化
				newAddr := fmt.Sprintf(":%d", listenPort)
				if newAddr != addr {
					log.Printf("Port changed: %s -> %s, restarting...", addr, newAddr)
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

	// 主循环
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
