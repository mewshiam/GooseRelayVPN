// relay-tunnel client: SOCKS5 listener that tunnels TCP through Apps Script.
package main

import (
	"context"
	"flag"
	"log"
	"os"
	"os/signal"
	"syscall"

	"github.com/kianmhz/relay-tunnel/internal/carrier"
	"github.com/kianmhz/relay-tunnel/internal/config"
	"github.com/kianmhz/relay-tunnel/internal/session"
	"github.com/kianmhz/relay-tunnel/internal/socks"
)

func main() {
	configPath := flag.String("config", "client_config.json", "path to client config JSON")
	flag.Parse()

	cfg, err := config.LoadClient(*configPath)
	if err != nil {
		log.Fatalf("config: %v", err)
	}

	carr, err := carrier.New(carrier.Config{
		ScriptURL: cfg.ScriptURL,
		AESKeyHex: cfg.AESKeyHex,
		Fronting: carrier.FrontingConfig{
			GoogleIP: cfg.GoogleIP,
			SNIHost:  cfg.SNIHost,
		},
	})
	if err != nil {
		log.Fatalf("carrier: %v", err)
	}

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	go func() {
		if err := carr.Run(ctx); err != nil && ctx.Err() == nil {
			log.Fatalf("carrier run: %v", err)
		}
	}()

	factory := socks.SessionFactory(func(target string) *session.Session {
		return carr.NewSession(target)
	})

	go func() {
		log.Printf("[client] SOCKS5 listening on %s", cfg.ListenAddr)
		if err := socks.Serve(ctx, cfg.ListenAddr, factory); err != nil {
			log.Fatalf("socks: %v", err)
		}
	}()

	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM)
	<-sigCh
	log.Println("[client] shutting down")
	cancel()
}
