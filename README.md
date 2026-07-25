# gleshell

A **structured-data shell** written in [Gleam](https://gleam.run), inspired by [Nushell](https://www.nushell.sh).

Instead of piping opaque text between programs, gleshell pipelines pass typed values: strings, numbers, lists, records, and tables. Built-in commands like `ls`, `where`, and `select` work on that structure.

```text
gleshell:gleshell> ls | where type == file | select name size | first 5
╭──────┬──────╮
│ name │ size │
├──────┼──────┤
│ …    │ …    │
╰──────┴──────╯
```

## Quick start

Requires [Gleam](https://gleam.run/getting-started/) and Erlang (or use Nix):

```bash
# with Nix flake (dev shell: gleam, erlang, rebar3)
nix develop
gleam run                 # interactive REPL
gleam run -- -c 'ls | first 3'
gleam test

# or one-shot from the repo root
nix run . -- -c 'ls | first 3'

# or if gleam is already on PATH
gleam run
```

### REPL editing

The interactive REPL uses Erlang’s line editor (`edlin`):

| Key | Action |
|-----|--------|
| ↑ / ↓ or Ctrl+P / Ctrl+N | History |
| **Ctrl+R** | Reverse-i-search through history |
| Ctrl+A / Ctrl+E | Beginning / end of line |
| Ctrl+W | Delete previous word |
| Ctrl+C / Ctrl+G | Cancel search / interrupt |

History is persisted under the user cache as `gleshell-history` (OTP `shell_history`).

## Examples

```nu
# list files as a table, filter, project columns
ls | where type == file | select name size

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

# external programs (stdout captured as a string)
^uname -a
which ls
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
| Flags | `--flag` / `--flag value` |
| Force external | `^command args…` |
| Comments | `# …` |

## Built-ins

Filesystem: `ls`, `cd`, `pwd`, `cat`, `open`, `save`

Table/list: `where`/`filter`, `select`, `get`, `first`, `last`, `take`, `skip`, `sort-by`, `reverse`, `length`, `columns`, `table`, `flatten`, `uniq`, `wrap`, `unwrap`, `keys`, `values`

Data: `echo`, `range`, `lines`, `to json`, `from json`, `type`, `describe`, `env`, `sys`, `which`, `help`, `exit`

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
    env.gleam / sys.gleam
```

Output is colorized on a TTY (headers bold green, numbers purple, bools cyan,
dirs blue, errors red, …). Disable with `NO_COLOR=1`; force with `FORCE_COLOR=1`.

## Status

Early but usable: core pipeline model, tables, filters, JSON, and external commands work. Not a full Nushell clone (no closures/plugins yet). Contributions and experiments welcome.

## License

Apache-2.0 (same as the Gleam project template unless you change it).
