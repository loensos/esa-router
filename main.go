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
	"sync"
	"syscall"
	"time"
)

const (
	listenPort = 1000
	bufSize    = 131072
	connectTO  = 10 * time.Second
	idleTO     = 300 * time.Second
	writeTO    = 30 * time.Second
)

type Route struct {
	Path    string
	Backend string
}

var routes []Route
var configPath = "/root/trojan-router/config.toml"

func loadConfig() error {
	f, err := os.Open(configPath)
	if err != nil {
		return fmt.Errorf("open config: %w", err)
	}
	defer f.Close()

	routes = nil
	scanner := bufio.NewScanner(f)
	for scanner.Scan() {
		line := bytes.TrimSpace(scanner.Bytes())
		if len(line) == 0 || bytes.HasPrefix(line, []byte("//")) {
			continue
		}
		parts := bytes.Fields(line)
		if len(parts) >= 2 {
			routes = append(routes, Route{
				Path:    string(parts[0]),
				Backend: string(parts[1]),
			})
		}
	}
	return scanner.Err()
}

func findRoute(path string) *Route {
	for i := range routes {
		if bytes.HasPrefix([]byte(path), []byte(routes[i].Path)) {
			return &routes[i]
		}
	}
	return nil
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
	idx := bytes.Index(firstLine, []byte("\\r\n"))
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

	route := findRoute(path)
	if route == nil {
		log.Printf("Unknown path: %s", path)
		return
	}

	log.Printf("%s -> %s", path, route.Backend)

	target, err := net.DialTimeout("tcp", route.Backend, connectTO)
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

	if err := loadConfig(); err != nil {
		log.Fatalf("Load config failed: %v", err)
	}

	log.Printf("Loaded %d routes from %s", len(routes), configPath)

	ln, err := net.Listen("tcp", fmt.Sprintf(":%d", listenPort))
	if err != nil {
		log.Fatalf("Listen: %v", err)
	}

	log.Printf("Listening on :%d", listenPort)
	for _, r := range routes {
		log.Printf("  %s -> %s", r.Path, r.Backend)
	}

	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM, syscall.SIGHUP)

	go func() {
		for sig := range sigCh {
			if sig == syscall.SIGHUP {
				log.Println("Reloading config...")
				if err := loadConfig(); err != nil {
					log.Printf("Reload failed: %v", err)
					continue
				}
				log.Printf("Reloaded %d routes", len(routes))
				for _, r := range routes {
					log.Printf("  %s -> %s", r.Path, r.Backend)
				}
				continue
			}
			log.Println("Shutting down...")
			ln.Close()
			return
		}
	}()

	for {
		conn, err := ln.Accept()
		if err != nil {
			select {
			case <-sigCh:
				return
			default:
				continue
			}
		}
		go handle(conn)
	}
}
