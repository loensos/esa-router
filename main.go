package main

import (
\t"bufio"
\t"bytes"
\t"fmt"
\t"io"
\t"log"
\t"net"
\t"os"
\t"os/signal"
\t"strings"
\t"sync"
\t"syscall"
\t"time"
)

const (
\tdefaultPort = 1000
\tbufSize     = 131072
\tconnectTO   = 10 * time.Second
\tidleTO      = 300 * time.Second
\twriteTO     = 30 * time.Second
)

type Route struct {
\tPath    string
\tBackend string
}

var (
\troutes     []Route
\tconfigPath = "/root/trojan-router/config.toml"
\tlistenPort = defaultPort
)

func loadConfig() error {
\tf, err := os.Open(configPath)
\tif err != nil {
\t\treturn fmt.Errorf("open config: %w", err)
\t}
\tdefer f.Close()

\troutes = nil
\tlistenPort = defaultPort

\tscanner := bufio.NewScanner(f)
\tfor scanner.Scan() {
\t\tline := bytes.TrimSpace(scanner.Bytes())
\t\tif len(line) == 0 || bytes.HasPrefix(line, []byte("//")) {
\t\t\tcontinue
\t\t}

\t\tif bytes.HasPrefix(line, []byte("listen")) {
\t\t\tparts := bytes.Fields(line)
\t\t\tif len(parts) >= 3 && bytes.Equal(parts[1], []byte("=")) {
\t\t\t\taddr := strings.TrimSpace(string(parts[2]))
\t\t\t\taddr = strings.Trim(addr, "\"")
\t\t\t\taddr = strings.Trim(addr, "'")
\t\t\t\tif len(addr) > 0 && addr[0] == ':' {
\t\t\t\t\tportStr := addr[1:]
\t\t\t\t\tfmt.Sscanf(portStr, "%d", &listenPort)
\t\t\t\t}
\t\t\t}
\t\t\tcontinue
\t\t}

\t\tparts := bytes.Fields(line)
\t\tif len(parts) >= 2 {
\t\t\troutes = append(routes, Route{
\t\t\t\tPath:    string(parts[0]),
\t\t\t\tBackend: string(parts[1]),
\t\t\t})
\t\t}
\t}
\treturn scanner.Err()
}

func findRoute(path string) *Route {
\tfor i := range routes {
\t\tif bytes.HasPrefix([]byte(path), []byte(routes[i].Path)) {
\t\t\treturn &routes[i]
\t\t}
\t}
\treturn nil
}

func copyConn(src, dst net.Conn, name string, done chan<- error) {
\tbuf := make([]byte, bufSize)
\tfor {
\t\tsrc.SetReadDeadline(time.Now().Add(idleTO))
\t\tn, err := src.Read(buf)
\t\tif n > 0 {
\t\t\tdst.SetWriteDeadline(time.Now().Add(writeTO))
\t\t\tif _, werr := dst.Write(buf[:n]); werr != nil {
\t\t\t\tdone <- fmt.Errorf("%s write: %w", name, werr)
\t\t\t\treturn
\t\t\t}
\t\t}
\t\tif err != nil {
\t\t\tif err == io.EOF {
\t\t\t\tdone <- nil
\t\t\t} else {
\t\t\t\tdone <- fmt.Errorf("%s read: %w", name, err)
\t\t\t}
\t\t\treturn
\t\t}
\t}
}

func handle(conn net.Conn) {
\tdefer conn.Close()

\treader := bufio.NewReader(conn)
\tvar header bytes.Buffer

\tfor {
\t\tline, err := reader.ReadString('\n')
\t\tif err != nil {
\t\t\treturn
\t\t}
\t\theader.WriteString(line)
\t\tif line == "\r\n" || line == "\n" {
\t\t\tbreak
\t\t}
\t}

\tfirstLine := header.Bytes()
\tidx := bytes.Index(firstLine, []byte("\r\n"))
\tif idx < 0 {
\t\treturn
\t}
\tfields := bytes.Fields(firstLine[:idx])
\tif len(fields) < 2 {
\t\treturn
\t}
\tpath := string(fields[1])
\tpathBytes := []byte(path)
\tif q := bytes.Index(pathBytes, []byte("?")); q >= 0 {
\t\tpath = string(pathBytes[:q])
\t}

\troute := findRoute(path)
\tif route == nil {
\t\tlog.Printf("Unknown path: %s", path)
\t\treturn
\t}

\tlog.Printf("%s -> %s", path, route.Backend)

\ttarget, err := net.DialTimeout("tcp", route.Backend, connectTO)
\tif err != nil {
\t\tlog.Printf("Backend error: %v", err)
\t\treturn
\t}
\tdefer target.Close()

\tif _, err := target.Write(header.Bytes()); err != nil {
\t\tlog.Printf("Header write error: %v", err)
\t\treturn
\t}

\tc2b := make(chan error, 1)
\tb2c := make(chan error, 1)

\tgo copyConn(conn, target, "C->B", c2b)
\tgo copyConn(target, conn, "B->C", b2c)

\tvar wg sync.WaitGroup
\twg.Add(2)
\tgo func() { c2b <- <-c2b; wg.Done() }()
\tgo func() { b2c <- <-b2c; wg.Done() }()
\twg.Wait()

\tlog.Printf("Done: C->B=%v, B->C=%v", <-c2b, <-b2c)
}

func main() {
\tlog.SetFlags(log.Ltime | log.Lmsgprefix)
\tlog.SetPrefix("[router] ")

\tif err := loadConfig(); err != nil {
\t\tlog.Fatalf("Load config failed: %v", err)
\t}

\tlog.Printf("Loaded %d routes from %s", len(routes), configPath)

\taddr := fmt.Sprintf(":%d", listenPort)
\tln, err := net.Listen("tcp", addr)
\tif err != nil {
\t\tlog.Fatalf("Listen: %v", err)
\t}

\tlog.Printf("Listening on %s", addr)
\tfor _, r := range routes {
\t\tlog.Printf("  %s -> %s", r.Path, r.Backend)
\t}

\tsigCh := make(chan os.Signal, 1)
\tsignal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM, syscall.SIGHUP)

\tgo func() {
\t\tfor sig := range sigCh {
\t\t\tif sig == syscall.SIGHUP {
\t\t\t\tlog.Println("Reloading config...")
\t\t\t\tif err := loadConfig(); err != nil {
\t\t\t\t\tlog.Printf("Reload failed: %v", err)
\t\t\t\t\tcontinue
\t\t\t\t}
\t\t\t\tlog.Printf("Reloaded %d routes", len(routes))
\t\t\t\tfor _, r := range routes {
\t\t\t\t\tlog.Printf("  %s -> %s", r.Path, r.Backend)
\t\t\t\t}
\t\t\t\tcontinue
\t\t\t}
\t\t\tlog.Println("Shutting down...")
\t\t\tln.Close()
\t\t\treturn
\t\t}
\t}()

\tfor {
\t\tconn, err := ln.Accept()
\t\tif err != nil {
\t\t\tselect {
\t\t\tcase <-sigCh:
\t\t\t\treturn
\t\t\tdefault:
\t\t\t\tcontinue
\t\t\t}
\t\t}
\t\tgo handle(conn)
\t}
}
