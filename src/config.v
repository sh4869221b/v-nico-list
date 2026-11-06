module main

import os
import strconv
import time
import math

struct Config {
mut:
	comment          int
	after            string = '10000101'
	before           string = '99991231'
	after_unix       i64
	before_unix      i64
	url              bool
	targets          int = 3
	pages            int = 1
	http             int
	adaptive         bool
	explicit_targets bool
	explicit_pages   bool
	explicit_http    bool
	metrics          bool
	timeout          time.Duration = 10 * time.second
	retries          int           = 10
	rate             f64
	interval         time.Duration
	input_file       string
	stdin            bool
	logfile          string
	progress         bool
	no_progress      bool
	strict           bool
	best_effort      bool
	dedupe           bool
	no_sort          bool
	json             bool
	help             bool
	version          bool
	base             string = 'https://nvapi.nicovideo.jp/v3'
	args             []string
}

fn parse_duration(s string) !time.Duration {
	if s == '0' { return 0 }
	mut text := s
	mut sign := i64(1)
	if text.starts_with('-') {
		sign = -1
		text = text[1..]
	} else if text.starts_with('+') {
		text = text[1..]
	}
	if text == '0' { return 0 }
	if text.len == 0 { return error('invalid duration: ${s}') }
	mut total := f64(0)
	mut pos := 0
	for pos < text.len {
		start := pos
		for pos < text.len && (text[pos].is_digit() || text[pos] == `.`) { pos++ }
		if pos == start { return error('invalid duration: ${s}') }
		num := strconv.atof64(text[start..pos])!
		unit_start := pos
		for pos < text.len && !text[pos].is_digit() && text[pos] != `.` { pos++ }
		unit := text[unit_start..pos]
		factor := match unit {
			'ns' { f64(time.nanosecond) }
			'us', 'µs', 'μs' { f64(time.microsecond) }
			'ms' { f64(time.millisecond) }
			's' { f64(time.second) }
			'm' { f64(time.minute) }
			'h' { f64(time.hour) }
			else { return error('invalid duration: ${s}') }
		}
		total += num * factor
	}
	if !math.is_finite(total) || total >= 9.2233720368547758e18 {
		return error('invalid duration: ${s}')
	}
	return time.Duration(i64(total) * sign)
}

fn parse_cli_int(s string) !int {
	return int(strconv.parse_int(s, 0, int(sizeof(int)) * 8)!)
}

fn parse_bool(s string) !bool {
	return match s {
		'1', 't', 'T', 'true', 'TRUE', 'True' { true }
		'0', 'f', 'F', 'false', 'FALSE', 'False' { false }
		else { return error('invalid boolean: ${s}') }
	}
}

fn flag_name(s string) string {
	return match s {
		'c' { 'comment' }
		'a' { 'dateafter' }
		'b' { 'datebefore' }
		'u' { 'url' }
		'T' { 'concurrency-targets' }
		'P' { 'concurrency-pages' }
		'H' { 'concurrency-http' }
		'A' { 'concurrency-adaptive' }
		'h' { 'help' }
		'v' { 'version' }
		else { s }
	}
}

fn parse_config(args []string) !Config {
	mut cfg := Config{}
	if base := os.getenv_opt('NICO_BASE_URL') { cfg.base = base.trim_right('/') }
	bools := ['url', 'concurrency-adaptive', 'http-metrics', 'stdin', 'progress', 'no-progress',
		'strict', 'best-effort', 'dedupe', 'no-sort', 'json', 'help', 'version']
	values := ['comment', 'dateafter', 'datebefore', 'concurrency-targets', 'concurrency-pages',
		'concurrency-http', 'timeout', 'retries', 'rate-limit', 'min-interval', 'input-file', 'logfile']
	mut i := 0
	mut flags := true
	for i < args.len {
		a := args[i]
		i++
		if flags && a == '--' {
			flags = false
			continue
		}
		if !flags || a == '-' || !a.starts_with('-') {
			cfg.args << a
			continue
		}
		mut parts := []string{}
		if a.starts_with('--') {
			parts << a[2..]
		} else {
			mut rest := a[1..]
			for rest.len > 0 {
				name := flag_name(rest[..1])
				if name in bools {
					if rest.len > 1 && rest[1] == `=` {
						parts << name + rest[1..]
						break
					}
					parts << name
					rest = rest[1..]
				} else {
					parts << if rest.len > 1 {
						name + '=' + if rest[1] == `=` { rest[2..] } else { rest[1..] }
					} else {
						name
					}
					break
				}
			}
		}
		for part in parts {
			name := part.all_before('=')
			if name !in bools && name !in values { return error('unknown flag: --${name}') }
			mut val := ''
			if part.contains('=') {
				val = part.all_after('=')
			} else if name in bools {
				val = 'true'
			} else {
				if i >= args.len { return error('flag needs an argument: --${name}') }
				val = args[i]
				i++
			}
			match name {
				'comment' { cfg.comment = parse_cli_int(val)! }
				'dateafter' { cfg.after = val }
				'datebefore' { cfg.before = val }
				'concurrency-targets' {
					cfg.targets = parse_cli_int(val)!
					cfg.explicit_targets = true
				}
				'concurrency-pages' {
					cfg.pages = parse_cli_int(val)!
					cfg.explicit_pages = true
				}
				'concurrency-http' {
					cfg.http = parse_cli_int(val)!
					cfg.explicit_http = true
				}
				'concurrency-adaptive' { cfg.adaptive = parse_bool(val)! }
				'http-metrics' { cfg.metrics = parse_bool(val)! }
				'timeout' { cfg.timeout = parse_duration(val)! }
				'retries' { cfg.retries = parse_cli_int(val)! }
				'rate-limit' { cfg.rate = strconv.atof64(val)! }
				'min-interval' { cfg.interval = parse_duration(val)! }
				'input-file' { cfg.input_file = val }
				'logfile' { cfg.logfile = val }
				'url' { cfg.url = parse_bool(val)! }
				'stdin' { cfg.stdin = parse_bool(val)! }
				'progress' { cfg.progress = parse_bool(val)! }
				'no-progress' { cfg.no_progress = parse_bool(val)! }
				'strict' { cfg.strict = parse_bool(val)! }
				'best-effort' { cfg.best_effort = parse_bool(val)! }
				'dedupe' { cfg.dedupe = parse_bool(val)! }
				'no-sort' { cfg.no_sort = parse_bool(val)! }
				'json' { cfg.json = parse_bool(val)! }
				'help' { cfg.help = parse_bool(val)! }
				'version' { cfg.version = parse_bool(val)! }
				else {}
			}
		}
	}
	if cfg.help || cfg.version { return cfg }
	if cfg.targets < 1 { return error('concurrency-targets must be at least 1') }
	if cfg.pages < 1 { return error('concurrency-pages must be at least 1') }
	if cfg.http < 0 { return error('concurrency-http must be >= 0') }
	if cfg.retries < 1 { return error('retries must be at least 1') }
	if cfg.timeout <= 0 { return error('timeout must be greater than 0') }
	if cfg.rate < 0 || !math.is_finite(cfg.rate) {
		return error('rate-limit must be at least 0 and finite')
	}
	if cfg.interval < 0 { return error('min-interval must be at least 0') }
	cfg.after_unix = parse_date(cfg.after) or { return error('dateafter format error') }
	cfg.before_unix = parse_date(cfg.before) or { return error('datebefore format error') }
	if cfg.after_unix > cfg.before_unix {
		return error('dateafter must be on or before datebefore')
	}
	cfg.before_unix += 86400
	return cfg
}

fn parse_date(s string) !i64 {
	if s.len != 8 || !all_digits(s) { return error('invalid date') }
	y := s[..4].int()
	m := s[4..6].int()
	d := s[6..].int()
	if y < 0 || m < 1 || m > 12 || d < 1 || d > time.days_in_month(m, y)! {
		return error('invalid date')
	}
	return time.new(time.Time{ year: y, month: m, day: d }).unix()
}

fn all_digits(s string) bool {
	if s.len == 0 { return false }
	for c in s { if !c.is_digit() { return false } }
	return true
}

const help_text = 'niconico user/mylist URL video list (V port)\nUsage: v-nico-list [flags] [URLs...]\n  -c, --comment number             lower comment limit (exclusive; default 0)\n  -a, --dateafter YYYYMMDD         inclusive UTC date (default 10000101)\n  -b, --datebefore YYYYMMDD        inclusive UTC date (default 99991231)\n  -u, --url                       output watch URLs\n  -T, --concurrency-targets int    target workers (default 3)\n  -P, --concurrency-pages int      page workers per target (default 1)\n  -H, --concurrency-http int       command-wide requests (default 0, unlimited)\n  -A, --concurrency-adaptive       adapt independently unspecified layers\n      --timeout duration          per-request deadline (default 10s)\n      --retries int               total request attempts (default 10)\n      --rate-limit float          requests per second (default 0)\n      --min-interval duration     minimum request interval (default 0)\n      --input-file path           newline inputs from file\n      --stdin                     newline inputs from stdin\n      --logfile path              append structured logs to file\n      --progress / --no-progress  control stderr progress\n      --strict / --best-effort    input/fetch exit behavior\n      --dedupe / --no-sort        output transforms\n      --json / --http-metrics     JSON output / aggregate diagnostic log\n  -h, --help                      show help\n  -v, --version                   show version'
