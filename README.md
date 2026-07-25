# gleshell

A **structured-data shell** written in [Gleam](https://gleam.run), inspired by [Nushell](https://www.nushell.sh).

Instead of piping opaque text between programs, gleshell pipelines pass typed values: strings, numbers, lists, records, and tables. Built-in commands like `ls`, `where`, and `select` work on that structure.

```text
~/code/gleshell on  main
❯ ls | where type == file | select name size | first 5
╭──────┬──────╮
│ name │ size │
├──────┼──────┤
│ …    │ …    │
╰──────┴──────╯
```

The interactive prompt is zero-config and Starship-inspired: full path with `~`,
optional git branch (read from `.git`, no external tools), and a `❯` character
that turns red after a non-zero exit.

## Quick start

Requires [Gleam](https://gleam.run/getting-started/) and Erlang (or use Nix):

```bash
# install a self-contained `gle` (Erlang shipment in the Nix store — no repo checkout)
nix profile install .
gle -c 'ls | first 3'

# one-shot without installing
nix run . -- -c 'ls | first 3'

# dev shell (source tree; gleam, erlang, rebar3)
# --no-pure-eval lets devenv use the real project dir (not /nix/store)
nix develop --no-pure-eval
gleam run                 # interactive REPL
gleam run -- -c 'ls | first 3'
gleam test
```

### REPL editing

On a TTY the interactive REPL uses a **raw-mode line editor** with
**Nushell-style syntax highlighting** as you type (commands cyan, strings
green, numbers purple, pipes purple, flags blue, variables purple, …).

| Key | Action |
|-----|--------|
| ↑ / ↓ | History |
| **Tab** | Command completion (builtins + `PATH`) at the start of a pipeline stage; filename completion for arguments (common prefix; list matches if ambiguous) |
| **Ctrl+R** | Reverse-i-search through history (Enter accepts onto the line) |
| Ctrl+A / Ctrl+E | Beginning / end of line |
| Ctrl+W | Delete previous word |
| Ctrl+U / Ctrl+K | Kill to start / end of line |
| Ctrl+L | Clear screen |
| **Ctrl+C** | Cancel current line at the prompt; while an external command runs, send SIGINT to that process (does not exit the shell) |
| Ctrl+D | EOF (empty line) or delete under cursor |

History is persisted under the user cache as `gleshell-history/lines`.
Non-TTY input falls back to Erlang’s `edlin`/`get_until` path.

## Examples

```nu
# list files as a table, filter, project columns
ls | where type == file | select name size
ls | find toml md
echo [moe larry curly] | find l

# ranges and list ops
range 10 | reverse | first 3
range 5 | length

# records and JSON
echo {name: "gleshell", cool: true}
echo "{\"a\": 1}" | from json | get a
open data.json | get users | first
range 3 | to json

# variables
let n = range 3 | length
echo $n

# process environment (Nushell-style)
$env.HOME
$env | get PATH
$env.MY_VAR = hello
echo $env.MY_VAR

# external programs (stdout captured as a string)
^uname -a
which ls
which -a ls
```

## Language sketch

| Feature | Syntax |
|--------|--------|
| Pipeline | `cmd \| cmd \| cmd` |
| Strings | `"hello"` or bare words `hello` |
| Numbers | `42`, `3.14` |
| Bools | `true` / `false` |
| Nothing | `null` / `nothing` |
| Lists | `[1 2 3]` |
| Records | `{name: alice, age: 30}` |
| Variables | `let x = …` then `$x` (pipeline input is `$in`) |
| Env | `$env`, `$env.HOME`, `$env.FOO = value` |
| Flags | `--flag` / `--flag value` |
| Force external | `^command args…` |
| Comments | `# …` |

## Built-ins

Filesystem: `ls`, `cd`, `pwd`, `cat`, `open`, `save`

Table/list: `where`/`filter`, `find`, `select`, `get`, `first`, `last`, `take`, `skip`, `sort-by`, `reverse`, `length`, `columns`, `table`, `flatten`, `uniq`, `wrap`, `unwrap`, `keys`, `values`

Data: `echo`, `range`, `lines`, `to`/`from` (subcommand `json`), `type`, `describe`, `env`, `sys`, `which`, `help`, `exit`

Unknown command names fall through to external executables on `PATH`.

## Layout

```text
src/
  gleshell.gleam          # entry + REPL
  gleshell_ffi.erl        # line editor (Ctrl+R), cwd, process spawn
  gleshell/
    value.gleam           # structured Value type
    lexer.gleam / parser.gleam
    eval.gleam            # pipeline evaluator
    builtins.gleam        # Nu-inspired commands
    display.gleam         # table pretty-printer
    color.gleam           # Nushell-style ANSI colors
    highlight.gleam       # live input syntax highlighting
    env.gleam / sys.gleam
```

Input and output are colorized on a TTY (Nu-like shapes on the command line;
headers bold green, numbers purple, bools cyan, dirs blue, errors red, …).
External tools (`jj`, `git`, `fastfetch`, …) keep their own colors: final-stage
commands inherit the real TTY (or get `FORCE_COLOR` when output is captured), and
pre-colored text is not re-painted by the shell. While the raw line editor is
active, the TTY is switched to cooked mode for those children so LF-only
output does not staircase. Paginated output gets `LESS=FRX` when unset so
`less` passes ANSI through.
Disable with `NO_COLOR=1`; force with `FORCE_COLOR=1`.

## Status

Early but usable: core pipeline model, tables, filters, JSON, and external commands work. Not a full Nushell clone (no closures/plugins yet). Contributions and experiments welcome.

## License

Apache-2.0 (same as the Gleam project template unless you change it).
