package main

import (
	"flag"
	"log"
	"net/http"
)

func main() {
	var addr string
	var root string
	flag.StringVar(&addr, "addr", "127.0.0.1:8123", "listen address")
	flag.StringVar(&root, "root", ".", "directory to serve")
	flag.Parse()

	log.Printf("serving %s on http://%s\n", root, addr)
	handler := http.FileServer(http.Dir(root))
	if err := http.ListenAndServe(addr, handler); err != nil {
		log.Fatal(err)
	}
}
