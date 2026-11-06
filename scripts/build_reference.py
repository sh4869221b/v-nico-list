#!/usr/bin/env python3
"""Build a fixture-enabled Go reference launcher without changing its checkout."""

import argparse
import os
from pathlib import Path
import subprocess
import tempfile

BASELINE = "6638228b9acfa6256805f5e57bdd75f4ca80e084"
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--source", required=True, help="read-only go-nico-list checkout")
parser.add_argument("--go", default="go")
parser.add_argument("--output", default="bin/go-nico-list-reference")
args = parser.parse_args()
source = Path(args.source).resolve()
revision = subprocess.check_output(["git", "-C", str(source), "rev-parse", "HEAD"], text=True).strip()
if revision != BASELINE:
    parser.error("reference revision must be " + BASELINE + "; got " + revision)
output = Path(args.output).resolve()
output.parent.mkdir(parents=True, exist_ok=True)
with tempfile.TemporaryDirectory(prefix="nico-go-reference-") as temp:
    root = Path(temp)
    # The exported command constructor is a supported injection boundary. Only
    # the temporary entrypoint differs: its API base comes from NICO_BASE_URL.
    (root / "main.go").write_text('''package main
import (
    "context"
    "fmt"
    "os"
    "os/signal"
    "syscall"
    "github.com/sh4869221b/go-nico-list/cmd"
)
func main() {
    cfg := cmd.DefaultConfig()
    if base := os.Getenv("NICO_BASE_URL"); base != "" { cfg.BaseURL = base }
    ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
    defer cancel()
    command := cmd.NewRootCommand(cfg, cmd.DefaultDeps())
    if err := command.ExecuteContext(ctx); err != nil { fmt.Fprintln(os.Stderr, err); os.Exit(1) }
}
''', encoding="utf-8")
    (root / "go.mod").write_text("module fixture-reference\n\ngo 1.27.0\n\nrequire github.com/sh4869221b/go-nico-list v0.0.0\n\nreplace github.com/sh4869221b/go-nico-list => " + source.as_posix() + "\n", encoding="utf-8")
    environment = os.environ.copy()
    environment.setdefault("GOTELEMETRY", "off")
    environment.setdefault("GOCACHE", str(Path(tempfile.gettempdir()) / "nico-go-build-cache"))
    environment.setdefault("GOMODCACHE", str(Path(tempfile.gettempdir()) / "nico-go-module-cache"))
    environment.setdefault("GOPATH", str(Path(tempfile.gettempdir()) / "nico-go-path"))
    environment.setdefault("GOTOOLCHAIN", "local")
    subprocess.run([args.go, "mod", "tidy"], cwd=root, env=environment, check=True)
    subprocess.run([args.go, "build", "-buildvcs=false", "-trimpath", "-o", str(output), "."], cwd=root, env=environment, check=True)
print(str(output))
