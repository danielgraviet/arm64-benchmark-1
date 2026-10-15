// natstap: passive NATS timestamp tap for the create-path measurement.
// Writes one TSV line per message: recv_unix_ns, subject, vm_id, job_id, status.
// Job payloads carry tokens/secrets: only ids are extracted, nothing else is stored.
package main

import (
	"bufio"
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"os/signal"
	"sync"
	"syscall"
	"time"

	"github.com/nats-io/nats.go"
)

func main() {
	url := flag.String("url", "nats://127.0.0.1:4222", "")
	token := flag.String("token", "", "")
	out := flag.String("out", "tap.tsv", "")
	flag.Parse()
	nc, err := nats.Connect(*url, nats.Token(*token), nats.Name("rlp-natstap"))
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	f, _ := os.Create(*out)
	w := bufio.NewWriterSize(f, 1<<20)
	var mu sync.Mutex
	h := func(m *nats.Msg) {
		t := time.Now().UnixNano()
		var p struct {
			VmID  string `json:"vm_id"`
			JobID string `json:"job_id"`
			Data  struct {
				Status string `json:"status"`
			} `json:"data"`
		}
		if len(m.Data) > 0 && m.Data[0] == '{' {
			_ = json.Unmarshal(m.Data, &p)
		}
		st := p.Data.Status
		if len(m.Data) > 0 && m.Data[0] != '{' && len(m.Data) < 16 {
			st = string(m.Data) // ack/nak bodies: +ACK, -NAK, +WPI, +TERM
		}
		mu.Lock()
		fmt.Fprintf(w, "%d\t%s\t%s\t%s\t%s\n", t, m.Subject, p.VmID, p.JobID, st)
		mu.Unlock()
	}
	for _, s := range []string{"jobs.vm.create.linux.>", "$JS.ACK.JOBS.>", "events.vm.>", "events.job.>"} {
		if _, err := nc.Subscribe(s, h); err != nil {
			fmt.Fprintln(os.Stderr, s, err)
			os.Exit(1)
		}
	}
	nc.Flush()
	fmt.Fprintln(os.Stderr, "natstap ready")
	sig := make(chan os.Signal, 1)
	signal.Notify(sig, syscall.SIGTERM, syscall.SIGINT)
	tick := time.NewTicker(time.Second)
	for {
		select {
		case <-tick.C:
			mu.Lock(); w.Flush(); mu.Unlock()
		case <-sig:
			nc.Drain()
			mu.Lock(); w.Flush(); f.Close(); mu.Unlock()
			return
		}
	}
}
