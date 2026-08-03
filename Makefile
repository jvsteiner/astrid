# Astrid — build & install for the Codewall baseline (dev/codewall)
#
# Why this exists: installing with `cp` over an existing binary silently
# bricks it. macOS caches a binary's code signature against its inode; a
# rewrite in place leaves a stale cache that no longer matches the bytes, and
# the kernel SIGKILLs it on exec ("killed: 9"). It looks exactly like a broken
# build, and it is not — `target/release/astrid` runs fine the whole time.
#
# So: `install` always removes the destination and moves a fresh file into
# place, then RUNS each binary before declaring success.

SHELL       := /bin/bash
PREFIX      ?= /opt/homebrew/bin
BINS        := astrid astrid-daemon astrid-build astrid-emit
TARGET      := target/release
BACKUP_DIR  ?= $(PREFIX)/.astrid-backup-$(shell date +%Y%m%d-%H%M%S)
ASTRID_HOME ?= $(HOME)/.astrid
LOCK        := $(ASTRID_HOME)/run/system.lock

.PHONY: help build install uninstall-safe backup restore verify status restart stop start doctor clean-target all

help:
	@echo "Astrid — Codewall baseline ($$(git rev-parse --abbrev-ref HEAD 2>/dev/null))"
	@echo
	@echo "  make all        build + install + restart   (the usual one)"
	@echo "  make build      cargo build --release"
	@echo "  make install    backup, install safely, verify each binary runs"
	@echo "  make restart    stop the daemon, clear a stale lock, start it"
	@echo "  make status     what is built vs what is installed"
	@echo "  make verify     prove every installed binary actually executes"
	@echo "  make doctor     signatures, daemon, principal"
	@echo "  make restore    put the newest backup back (safely)"
	@echo
	@echo "  PREFIX=$(PREFIX)"

all: build install restart verify

build:
	cargo build --release --locked -p astrid -p astrid-daemon
	@for b in $(BINS); do \
	  test -x $(TARGET)/$$b || { echo "!! $(TARGET)/$$b missing after build"; exit 1; }; \
	done
	@echo "built: $$(git rev-parse --abbrev-ref HEAD)@$$(git rev-parse --short HEAD)"

# Prove the freshly-built binaries work BEFORE touching anything installed.
# If this fails, the build is genuinely broken and install must not proceed.
build-check:
	@for b in $(BINS); do \
	  printf "  %-14s " $$b; \
	  $(TARGET)/$$b --version 2>/dev/null || { echo "FAILS TO RUN"; exit 1; }; \
	done

backup:
	@mkdir -p $(BACKUP_DIR)
	@for b in $(BINS); do \
	  if [ -e $(PREFIX)/$$b ]; then cp -p $(PREFIX)/$$b $(BACKUP_DIR)/$$b; fi; \
	done
	@echo "backed up to $(BACKUP_DIR)"

# The safe install. Note `rm` then `mv` — never `cp` onto a live path.
install: build-check backup
	@for b in $(BINS); do \
	  rm -f $(PREFIX)/$$b; \
	  cp $(TARGET)/$$b $(PREFIX)/$$b.tmp.$$$$; \
	  mv -f $(PREFIX)/$$b.tmp.$$$$ $(PREFIX)/$$b; \
	  chmod 755 $(PREFIX)/$$b; \
	done
	@$(MAKE) --no-print-directory verify

# An install that cannot be verified is a broken install; say so loudly.
verify:
	@ok=1; for b in $(BINS); do \
	  printf "  %-14s " $$b; \
	  out=$$($(PREFIX)/$$b --version 2>&1); \
	  if [ -z "$$out" ]; then echo "** KILLED / NO OUTPUT — see 'make doctor' **"; ok=0; \
	  else echo "$$out"; fi; \
	done; \
	[ $$ok -eq 1 ] || { echo; echo "Install did NOT verify. 'make restore' puts the last backup back."; exit 1; }

stop:
	@pkill -f 'astrid-daemon' 2>/dev/null || true
	@sleep 2
	@pkill -9 -f 'astrid-daemon' 2>/dev/null || true
	@sleep 1
	@if [ -f $(LOCK) ] && ! pgrep -f astrid-daemon >/dev/null 2>&1; then \
	  rm -f $(LOCK); echo "  cleared stale lock"; fi
	@echo "  daemon stopped"

start:
	@$(PREFIX)/astrid start >/dev/null 2>&1 || true
	@for i in $$(seq 1 15); do \
	  if $(PREFIX)/astrid status >/dev/null 2>&1; then echo "  daemon up"; exit 0; fi; \
	  sleep 1; \
	done; \
	echo "  daemon did not become ready in 15s — 'make doctor', or check $(ASTRID_HOME)/log"

# A running daemon keeps the OLD binary mapped. Reinstalling without this
# leaves you running code you did not just build.
restart: stop start

status:
	@echo "branch:    $$(git rev-parse --abbrev-ref HEAD 2>/dev/null)@$$(git rev-parse --short HEAD 2>/dev/null)"
	@echo "prefix:    $(PREFIX)"
	@for b in $(BINS); do \
	  printf "  %-14s built=%-8s installed=%s\n" $$b \
	    "$$(ls -lh $(TARGET)/$$b 2>/dev/null | awk '{print $$5}')" \
	    "$$(ls -lh $(PREFIX)/$$b 2>/dev/null | awk '{print $$5}')"; \
	done
	@printf "daemon:    "; pgrep -f astrid-daemon >/dev/null && echo "running (pid $$(pgrep -f astrid-daemon | head -1))" || echo "not running"
	@printf "principal: "; cat $(ASTRID_HOME)/run/session.principal 2>/dev/null || echo "(none)"

doctor:
	@echo "== do installed binaries execute? =="
	@for b in $(BINS); do \
	  printf "  %-14s " $$b; \
	  $(PREFIX)/$$b --version 2>&1 | head -1 || echo "KILLED — stale signature cache; run 'make install'"; \
	done
	@echo "== code signatures =="
	@for b in $(BINS); do \
	  printf "  %-14s " $$b; \
	  codesign -dv $(PREFIX)/$$b 2>&1 | grep -o 'flags=.*' | head -1 || echo "(unsigned/unreadable)"; \
	done
	@echo "== daemon =="
	@ps -eo pid,etime,command | grep '[a]strid-daemon' | head -3 | sed 's/^/  /' || echo "  not running"
	@echo "== lock =="
	@if [ -f $(LOCK) ]; then \
	  pgrep -f astrid-daemon >/dev/null && echo "  held by a live daemon (fine)" || echo "  STALE — 'make stop' clears it"; \
	else echo "  none"; fi

restore:
	@last=$$(ls -dt $(PREFIX)/.astrid-backup-* 2>/dev/null | head -1); \
	[ -n "$$last" ] || { echo "no backup found"; exit 1; }; \
	echo "restoring from $$last"; \
	for b in $(BINS); do \
	  [ -e $$last/$$b ] || continue; \
	  rm -f $(PREFIX)/$$b; \
	  cp $$last/$$b $(PREFIX)/$$b.tmp.$$$$; \
	  mv -f $(PREFIX)/$$b.tmp.$$$$ $(PREFIX)/$$b; \
	  chmod 755 $(PREFIX)/$$b; \
	done; \
	$(MAKE) --no-print-directory verify

clean-target:
	rm -rf $(TARGET)
