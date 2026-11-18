module main

const max_page_workers = 32

struct PageResult {
	number int
	page   Page
	error  string
}

struct TargetResult {
	kind  string @[json: 'type']
	id    string
	items []string
	error string
	order int @[json: '-']
}

fn cancellation_error(message string) bool {
	return message == 'context canceled' || message == 'context deadline exceeded'
}

fn request_url(cfg Config, t Target, page int) string {
	path := if t.kind == 'user' { '/users/${t.id}/videos' } else { '/mylists/${t.id}' }
	return '${cfg.base}${path}?pageSize=100&page=${page}'
}

fn fetch_page(cfg Config, t Target, page int, mut c Control) !Page {
	c.add_counter('pages', 1)
	mut last := ''
	mut delay := i64(0)
	for attempt := 1; attempt <= cfg.retries; attempt++ {
		if delay > 0 { sleep_cancel(delay)! }
		permit := c.acquire_http(attempt)!
		response := transport_get(request_url(cfg, t, page), cfg.timeout, c) or {
			if err.code() == 20001 {
				c.finish_http(permit, 200, false, 0, 0)
				c.add_counter('body_errors', 1)
				c.add_counter('page_errors', 1)
				return err
			}
			c.finish_http(permit, 0, true, 0, 0)
			if c.stopped() { return error('context canceled') }
			if err.code() == 20002 || err.code() == 20003 || cancellation_error(err.msg()) {
				return error('context deadline exceeded')
			}
			last = err.msg()
			delay = retry_delay(attempt, 0)
			continue
		}
		delay = retry_delay(attempt, retry_after(response.headers, response.status))
		c.finish_http(permit, response.status, false, response.body.len, delay)
		if response.status == 404 {
			c.add_counter('page_success', 1)
			return Page{ not_found: true }
		}
		if response.status != 200 {
			last = 'unexpected status: ${response.status}'
			continue
		}
		started := now_ns()
		parsed := parse_page(response.body.bytestr(), t.kind) or {
			c.add_counter('decode_errors', 1)
			c.add_counter('page_errors', 1)
			return err
		}
		c.mu.lock()
		c.durations['decode_ns'] += now_ns() - started
		c.mu.unlock()
		if parsed.status != 200 {
			c.log_event('WARN', 'unexpected meta status', {
				'status': parsed.status
			})
		}
		c.add_counter('page_success', 1)
		return parsed
	}
	c.add_counter('page_errors', 1)
	return error(last)
}

fn fetch_page_worker(cfg Config, t Target, mut c Control, jobs chan int, results chan PageResult) {
	for {
		page := <-jobs or { break }
		p := fetch_page(cfg, t, page, mut c) or {
			results <- PageResult{ number: page, error: err.msg() }
			continue
		}
		results <- PageResult{ number: page, page: p }
	}
}

fn collect_target(cfg Config, t Target, mut c Control) TargetResult {
	mut items := []string{}
	first := fetch_page(cfg, t, 1, mut c) or {
		return TargetResult{
			kind:  t.kind
			id:    t.id
			error: if cancellation_error(err.msg()) {
				''
			} else {
				err.msg()
			}
			order: t.order
		}
	}
	if first.not_found || first.items.len == 0 {
		return TargetResult{ kind: t.kind, id: t.id, order: t.order }
	}
	items << filter_page(first, cfg)
	adaptive_pages := cfg.adaptive && !cfg.explicit_pages
	if (!adaptive_pages && cfg.pages == 1) || !first.has_total {
		for page := 2; ; page++ {
			p := fetch_page(cfg, t, page, mut c) or {
				return TargetResult{
					kind:  t.kind
					id:    t.id
					items: if cancellation_error(err.msg()) {
						[]string{}
					} else {
						items
					}
					error: if cancellation_error(err.msg()) { '' } else { err.msg() }
					order: t.order
				}
			}
			if p.not_found || p.items.len == 0 { break }
			items << filter_page(p, cfg)
		}
	} else {
		total := if first.total > 0 { 1 + (first.total - 1) / 100 } else { i64(0) }
		if sizeof(int) == 4 && total > 2147483647 {
			return TargetResult{ kind: t.kind, id: t.id, items: items, error: 'totalCount requires too many pages', order: t.order }
		}
		// Reuse workers up to the effective cap. The ordered window also
		// bounds completed pages waiting for an earlier result.
		worker_cap := if cfg.http > 0 {
			int_min(max_page_workers, cfg.http)
		} else {
			max_page_workers
		}
		jobs := chan int{cap: worker_cap}
		ch := chan PageResult{cap: 16}
		mut workers := []thread{cap: worker_cap}
		defer {
			jobs.close()
			workers.wait()
		}
		mut active := 0
		mut next := i64(2)
		mut commit := i64(2)
		mut stop := false
		mut terminal := total + 1
		mut failure := ''
		mut pending := map[i64]PageResult{}
		for active > 0 || (!stop && next <= total) {
			c.mu.lock()
			limit := int_min(worker_cap, if adaptive_pages { c.budget } else { cfg.pages })
			c.mu.unlock()
			for !stop && next <= total && active < limit && next - commit < i64(limit) {
				if c.stopped() {
					stop = true
					failure = 'context canceled'
					break
				}
				if active == workers.len {
					workers << spawn fetch_page_worker(cfg, t, mut c, jobs, ch)
				}
				jobs <- int(next)
				next++
				active++
			}
			if active == 0 { break }
			waiting := !stop && next <= total
			if waiting {
				c.mu.lock()
				c.page_pending++
				c.mu.unlock()
			}
			r := <-ch
			active--
			if waiting {
				c.mu.lock()
				c.page_pending--
				c.mu.unlock()
			}
			pending[i64(r.number)] = r
			if r.error != '' || r.page.not_found || r.page.items.len == 0 {
				terminal = ns_min(terminal, i64(r.number))
				stop = true
			}
			for (commit in pending) {
				rp := pending[commit]
				pending.delete(commit)
				if commit >= terminal {
					failure = rp.error
					break
				}
				items << filter_page(rp.page, cfg)
				commit++
			}
		}
		// A lower page may have terminated after a higher one. Read its own
		// error, rather than whichever parallel failure happened to finish first.
		if terminal in pending { failure = pending[terminal].error }
		if failure != '' {
			return TargetResult{
				kind:  t.kind
				id:    t.id
				items: if cancellation_error(failure) {
					[]string{}
				} else {
					items
				}
				error: if cancellation_error(failure) { '' } else { failure }
				order: t.order
			}
		}
	}
	return TargetResult{ kind: t.kind, id: t.id, items: items, order: t.order }
}

fn target_worker(cfg Config, t Target, mut c Control, ch chan TargetResult) {
	r := collect_target(cfg, t, mut c)
	if cfg.no_sort && !cfg.json { c.emit_items(r.items) }
	ch <- r
}
