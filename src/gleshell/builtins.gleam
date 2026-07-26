//// Built-in commands (Nushell-inspired structured data tools).

import filepath
import gleam/bit_array
import gleam/dict
import gleam/dynamic/decode
import gleam/float
import gleam/http
import gleam/http/request
import gleam/http/response
import gleam/httpc
import gleam/int
import gleam/json
import gleam/list
import gleam/option
import gleam/order
import gleam/string
import gleshell/color
import gleshell/display
import gleshell/env.{type Env}
import gleshell/pager
import gleshell/syntax
import gleshell/sys
import gleshell/value.{
  type Value, Bool, Fail, Float, Int, List, Nothing, Record, String, Table,
}
import simplifile

pub type BuiltinResult {
  BuiltinResult(env: Env, value: Value)
  Exit(code: Int)
}

pub type Builtin =
  fn(Env, Value, List(Value), dict.Dict(String, Value)) -> BuiltinResult

pub fn registry() -> dict.Dict(String, Builtin) {
  dict.from_list([
    #("help", cmd_help),
    #("echo", cmd_echo),
    #("print", cmd_echo),
    #("ls", cmd_ls),
    #("pwd", cmd_pwd),
    #("cd", cmd_cd),
    #("cat", cmd_cat),
    #("open", cmd_open),
    #("save", cmd_save),
    #("where", cmd_where),
    #("filter", cmd_where),
    #("find", cmd_find),
    #("select", cmd_select),
    #("get", cmd_get),
    #("first", cmd_first),
    #("last", cmd_last),
    #("take", cmd_take),
    #("skip", cmd_skip),
    #("length", cmd_length),
    #("count", cmd_length),
    #("reverse", cmd_reverse),
    #("sort-by", cmd_sort_by),
    #("sort_by", cmd_sort_by),
    #("uniq", cmd_uniq),
    #("wrap", cmd_wrap),
    #("unwrap", cmd_unwrap),
    // Nushell-style: `to` / `from` with format subcommands (`json`)
    #("to", cmd_to),
    #("from", cmd_from),
    // Nushell-style: `http get|post|put|delete|patch|head`
    #("http", cmd_http),
    #("lines", cmd_lines),
    #("typeof", cmd_type),
    #("type", cmd_type),
    #("describe", cmd_describe),
    #("env", cmd_env),
    #("which", cmd_which),
    #("exit", cmd_exit),
    #("quit", cmd_exit),
    #("ignore", cmd_ignore),
    #("identity", cmd_identity),
    #("range", cmd_range),
    #("append", cmd_append),
    #("prepend", cmd_prepend),
    #("is-empty", cmd_is_empty),
    #("is_empty", cmd_is_empty),
    #("table", cmd_table),
    #("columns", cmd_columns),
    #("flatten", cmd_flatten),
    #("values", cmd_values),
    #("keys", cmd_keys),
    #("sys", cmd_sys),
    #("ps", cmd_ps),
    #("about", cmd_about),
    #("less", cmd_less),
  ])
}

pub fn names() -> List(String) {
  registry()
  |> dict.keys
  |> list.sort(string.compare)
}

/// Registered builtins that lack a dedicated `help_text` entry (should be empty).
pub fn missing_help() -> List(String) {
  list.filter(names(), fn(n) { !dict.has_key(help_text(), n) })
}

fn ok(env: Env, value: Value) -> BuiltinResult {
  BuiltinResult(env, value)
}

fn err(env: Env, msg: String) -> BuiltinResult {
  BuiltinResult(env.set_exit(env, 1), Fail(msg))
}

// --- help ---

fn cmd_help(
  env: Env,
  _input: Value,
  args: List(Value),
  _flags: dict.Dict(String, Value),
) -> BuiltinResult {
  case args {
    [String(name)] ->
      case help_for(name) {
        Ok(text) -> ok(env, String(text))
        Error(Nil) -> err(env, "unknown command: " <> name)
      }
    _ -> {
      let command_lines =
        list.map(names(), fn(n) {
          case help_line(n) {
            Ok(text) -> "  " <> text
            Error(Nil) -> "  " <> n
          }
        })
      let lines =
        list.append(
          [
            "gleshell — a Gleam shell inspired by Nushell",
            "",
            "Pipelines pass structured data (not just text):",
            "  ls | where type == file | select name size",
            "  open data.json | get users | first 3",
            "  range 5 | reverse",
            "",
            "Commands:",
          ],
          list.append(command_lines, [
            "",
            "Use `help <command>` for details. `^cmd` forces an external binary.",
            "Variables: `let x = ...` then `$x`. Pipeline input is `$in`.",
            "Env: `$env`, `$env.HOME`, `$env.FOO = bar` (process environment).",
          ]),
        )
      ok(env, String(string.join(lines, "\n")))
    }
  }
}

/// One-line help for a registered builtin, or Error if the name is not a builtin.
fn help_line(name: String) -> Result(String, Nil) {
  case dict.get(help_text(), name) {
    Ok(text) -> Ok(text)
    Error(Nil) ->
      case dict.has_key(registry(), name) {
        // Safety net if help_text drifts; `missing_help` / tests should catch this.
        True -> Ok(name <> " — builtin command")
        False -> Error(Nil)
      }
  }
}

/// Full help text for `help <name>`, including subcommands where relevant.
fn help_for(name: String) -> Result(String, Nil) {
  case name {
    "to" ->
      Ok(string.join(
        [
          "to <format> — convert pipeline input to a text format",
          "",
          "Subcommands:",
          "  json [--raw|-r] [--indent|-i n] — JSON string (pretty by default;",
          "                                   --raw is compact, no trailing newline)",
          "",
          "Examples:",
          "  range 3 | to json",
          "  ls | to json --raw",
        ],
        "\n",
      ))
    "from" ->
      Ok(string.join(
        [
          "from <format> — parse text input into structured data",
          "",
          "Subcommands:",
          "  json — parse a JSON string (pipeline input or a string argument)",
          "",
          "Examples:",
          "  open data.json | from json",
          "  echo '{\"a\": 1}' | from json | get a",
        ],
        "\n",
      ))
    "http" -> Ok(http_help_text())
    "cat" ->
      Ok(string.join(
        [
          "cat <path> — read a text file as a string",
          "",
          "On a color TTY: truecolor syntax highlight (json, gleam, toml,",
          "markdown), bat-style line numbers, and a filename header.",
          "Detection uses the extension, then a light content sniff.",
          "Binary files are refused.",
          "",
          "Flags:",
          "  -r, --raw                 plain text (no colors; safe for pipelines)",
          "  -l, --language <id>       force language (json|gleam|toml|markdown|plain)",
          "",
          "Examples:",
          "  cat README.md",
          "  cat src/gleshell.gleam",
          "  cat data.json --raw | from json",
          "  cat notes.txt --language markdown",
        ],
        "\n",
      ))
    "find" ->
      Ok(string.join(
        [
          "find [-i] [-v] [--regex pat] [--columns cols] <term>… — search pipeline input",
          "",
          "Filters lists/tables for items matching any term (OR). Strings use",
          "substring match; numbers/bools match by equality. Multi-line strings",
          "are split into lines (unless --multiline).",
          "",
          "Flags:",
          "  -i, --ignore-case     case-insensitive match",
          "  -v, --invert          keep non-matching items",
          "  -r, --regex <pat>     Erlang regex (not combined with terms)",
          "  -c, --columns <list>  only search these table columns",
          "  -m, --multiline       do not split multi-line strings into lines",
          "",
          "Examples:",
          "  ls | find toml md",
          "  echo [moe larry curly] | find l",
          "  echo [Hello world] | find hello -i",
          "  echo [abc odb abf] | find --regex \"b.\"",
        ],
        "\n",
      ))
    "less" ->
      Ok(string.join(
        [
          "less [file]… — page pipeline input or files (ANSI colors kept)",
          "",
          "Builtin pager inspired by less -FRX: colors from tools and gleshell",
          "tables pass through; if the text fits on one screen (or stdout is not",
          "a TTY), it is printed and the pager exits. Use `^less` for the",
          "external binary on PATH.",
          "",
          "Keys (interactive):",
          "  j / ↓ / Enter     line down     k / ↑        line up",
          "  space / f / PgDn  page down     b / PgUp     page up",
          "  g / Home          top           G / End      bottom",
          "  /pattern          live search   n / N        next/prev",
          "  h / ?             help          q / Ctrl+C   quit",
          "",
          "Examples:",
          "  ls | less",
          "  cat README.md | less",
          "  less README.md",
          "  ^jj log | less",
        ],
        "\n",
      ))
    "ps" ->
      Ok(string.join(
        [
          "ps [-l|--long] — view system processes as a table",
          "",
          "Inspired by Nushell `ps`. Default columns: pid, ppid, name, status,",
          "cpu, mem, virtual. With --long, also: command, start_time, user_id,",
          "process_group_id, session_id, priority, process_threads, working,",
          "paged, cwd.",
          "",
          "Flags:",
          "  -l, --long   include all available columns",
          "",
          "Examples:",
          "  ps",
          "  ps | sort-by mem | last 5",
          "  ps | sort-by cpu | last 3",
          "  ps --long | where name == beam.smp",
          "  ps | where pid == 1 | get name",
        ],
        "\n",
      ))
    _ -> help_line(name)
  }
}

fn help_text() -> dict.Dict(String, String) {
  dict.from_list([
    #("help", "help [command] — list builtins, or show help for one command"),
    #("echo", "echo <values>… — emit values (list if multiple)"),
    #("print", "print <values>… — alias for echo"),
    #(
      "ls",
      "ls [path] — list directory entries as a table (name, type, size, modified)",
    ),
    #("pwd", "pwd — print working directory"),
    #("cd", "cd [path] — change directory (~ supported)"),
    #(
      "cat",
      "cat <path> [--raw] [--language <id>] — read file; syntax-color on TTY",
    ),
    #("open", "open <path> — open file; parses .json into structured data"),
    #("save", "save <path> — save pipeline input to a file"),
    #(
      "where",
      "where <field> <op> <value> — filter rows (ops: == != > < >= <=)",
    ),
    #("filter", "filter <field> <op> <value> — alias for where"),
    #(
      "find",
      "find [-i] [-v] [--regex pat] <term>… — search list/table/string input for terms",
    ),
    #("select", "select <col>… — keep only named columns"),
    #("get", "get <field|index> — get a field or list index"),
    #("first", "first [n] — first row/item (default 1)"),
    #("last", "last [n] — last row/item"),
    #("take", "take <n> — take first n items"),
    #("skip", "skip <n> — skip first n items"),
    #("length", "length — number of items in list/table/string input"),
    #("count", "count — alias for length"),
    #("reverse", "reverse — reverse list, table rows, or string graphemes"),
    #("sort-by", "sort-by <field> — sort table rows by field"),
    #("sort_by", "sort_by <field> — alias for sort-by"),
    #("uniq", "uniq — drop duplicate list items (order preserved)"),
    #("wrap", "wrap <name> — wrap pipeline input as a single-field record"),
    #("unwrap", "unwrap [name] — unwrap a record field (default: first field)"),
    #(
      "to",
      "to <format> — convert pipeline input (subcommands: json)",
    ),
    #(
      "from",
      "from <format> — parse structured input (subcommands: json)",
    ),
    #(
      "http",
      "http <get|post|put|delete|patch|head> <url> [body] — HTTP client",
    ),
    #("lines", "lines — split string input into a list of lines"),
    #("typeof", "typeof — type name of pipeline input"),
    #("type", "type — alias for typeof"),
    #(
      "describe",
      "describe — record with type, length, and string form of input",
    ),
    #(
      "env",
      "env [NAME] — process environment table, or one var (same as `$env` / `$env.NAME`)",
    ),
    #(
      "which",
      "which [-a|--all] [-f|--follow] <name> — path of command (builtin or on PATH); -a all matches, -f follow symlinks",
    ),
    #("exit", "exit [code] — leave the shell (default code 0)"),
    #("quit", "quit [code] — alias for exit"),
    #("ignore", "ignore — discard pipeline input; emit nothing"),
    #("identity", "identity — pass pipeline input through unchanged"),
    #("range", "range <end> | range <start> <end> — integer range list"),
    #("append", "append <values>… — append values to list input"),
    #("prepend", "prepend <values>… — prepend values to list input"),
    #("is-empty", "is-empty — true if list/table/string input has length 0"),
    #("is_empty", "is_empty — alias for is-empty"),
    #(
      "table",
      "table — coerce list of records (or table) into a table",
    ),
    #("columns", "columns — column names of a table, or keys of a record"),
    #("flatten", "flatten — one level of list-of-lists flattening"),
    #("values", "values — list of values from a record"),
    #("keys", "keys — list of keys from a record"),
    #("sys", "sys — host info record (cwd, home, shell, last_exit)"),
    #(
      "ps",
      "ps [-l|--long] — system processes table (pid, name, cpu, mem, …)",
    ),
    #("about", "about — authorship, ATProto handle, and a little sparkle"),
    #(
      "less",
      "less [file]… — page pipeline input or files (ANSI colors kept)",
    ),
  ])
}

// --- echo ---

fn cmd_echo(
  env: Env,
  input: Value,
  args: List(Value),
  _flags: dict.Dict(String, Value),
) -> BuiltinResult {
  case args {
    [] -> ok(env, input)
    [single] -> ok(env, single)
    many -> ok(env, List(many))
  }
}

// --- fs ---

fn cmd_pwd(
  env: Env,
  _input: Value,
  _args: List(Value),
  _flags: dict.Dict(String, Value),
) -> BuiltinResult {
  ok(env, String(env.cwd))
}

fn cmd_cd(
  env: Env,
  _input: Value,
  args: List(Value),
  _flags: dict.Dict(String, Value),
) -> BuiltinResult {
  let target = case args {
    [] | [String("~")] ->
      case sys.home_dir() {
        Ok(h) -> h
        Error(_) -> "/"
      }
    [String(path)] -> resolve_path(env, path)
    _ -> ""
  }
  case target {
    "" -> err(env, "cd: expected path")
    path ->
      case env.set_cwd(env, path) {
        Ok(env2) -> ok(env2, Nothing)
        Error(e) -> err(env, "cd: " <> e)
      }
  }
}

fn resolve_path(env: Env, path: String) -> String {
  case path {
    "" -> env.cwd
    "~" ->
      case sys.home_dir() {
        Ok(h) -> h
        Error(_) -> path
      }
    _ ->
      case string.starts_with(path, "/") {
        True -> path
        False ->
          case string.starts_with(path, "~/") {
            True ->
              case sys.home_dir() {
                Ok(h) -> filepath.join(h, string.drop_start(path, 2))
                Error(_) -> path
              }
            False -> filepath.join(env.cwd, path)
          }
      }
  }
}

fn cmd_ls(
  env: Env,
  _input: Value,
  args: List(Value),
  _flags: dict.Dict(String, Value),
) -> BuiltinResult {
  let path = case args {
    [String(p)] -> resolve_path(env, p)
    _ -> env.cwd
  }
  case simplifile.read_directory(path) {
    Error(e) -> err(env, "ls: " <> simplifile.describe_error(e))
    Ok(names) -> {
      let names = list.sort(names, string.compare)
      let records =
        list.map(names, fn(name) {
          let full = filepath.join(path, name)
          case simplifile.file_info(full) {
            Error(_) ->
              Record([
                #("name", String(name)),
                #("type", String("unknown")),
                #("size", Int(0)),
                #("modified", Int(0)),
              ])
            Ok(info) -> {
              let ftype = case simplifile.file_info_type(info) {
                simplifile.File -> "file"
                simplifile.Directory -> "dir"
                simplifile.Symlink -> "symlink"
                simplifile.Other -> "other"
              }
              Record([
                #("name", String(name)),
                #("type", String(ftype)),
                #("size", Int(info.size)),
                #("modified", Int(info.mtime_seconds)),
              ])
            }
          }
        })
      ok(env, value.table_from_records(records))
    }
  }
}

fn cmd_cat(
  env: Env,
  _input: Value,
  args: List(Value),
  flags: dict.Dict(String, Value),
) -> BuiltinResult {
  // Boolean flags may steal the next word (`cat --raw path` → flag raw = path).
  let #(raw, stolen_r) = find_bool_flag(flags, ["raw", "r"])
  let lang_opt = cat_language_flag(flags)
  let path_candidates = list.append(args, stolen_r)
  case lang_opt, path_candidates {
    Error(msg), _ -> err(env, "cat: " <> msg)
    Ok(lang_override), [String(path)] -> {
      let path = resolve_path(env, path)
      case simplifile.read(path) {
        Error(e) -> err(env, "cat: " <> simplifile.describe_error(e))
        Ok(content) ->
          case syntax.is_binary(content) {
            True ->
              err(
                env,
                "cat: binary file (refusing to print; use an external tool)",
              )
            False -> {
              let language = case lang_override {
                option.Some(lang) -> lang
                option.None -> syntax.detect(path, content)
              }
              let painted = case raw {
                True -> content
                False ->
                  syntax.present(color.enabled(), language, path, content)
              }
              ok(env, String(painted))
            }
          }
      }
    }
    Ok(_), _ ->
      err(
        env,
        "cat: expected path (try `cat <path>`; --raw / --language <id> optional)",
      )
  }
}

/// `--language` / `-l` override. `Error` is a user-facing message.
fn cat_language_flag(
  flags: dict.Dict(String, Value),
) -> Result(option.Option(syntax.Language), String) {
  case dict.get(flags, "language"), dict.get(flags, "l") {
    Ok(v), _ -> cat_parse_language_value(v)
    _, Ok(v) -> cat_parse_language_value(v)
    Error(Nil), Error(Nil) -> Ok(option.None)
  }
}

fn cat_parse_language_value(
  v: Value,
) -> Result(option.Option(syntax.Language), String) {
  case v {
    Bool(True) | Nothing ->
      Error("language flag requires a name (json, gleam, toml, markdown, plain)")
    other -> {
      let name = value.as_string(other)
      case syntax.language_from_name(name) {
        Ok(lang) -> Ok(option.Some(lang))
        Error(Nil) ->
          Error(
            "unknown language `"
            <> name
            <> "` (try json, gleam, toml, markdown, plain)",
          )
      }
    }
  }
}

fn cmd_open(
  env: Env,
  _input: Value,
  args: List(Value),
  _flags: dict.Dict(String, Value),
) -> BuiltinResult {
  case args {
    [String(path)] -> {
      let path = resolve_path(env, path)
      case simplifile.read(path) {
        Error(e) -> err(env, "open: " <> simplifile.describe_error(e))
        Ok(content) ->
          case string.ends_with(string.lowercase(path), ".json") {
            True ->
              case parse_json_value(content) {
                Ok(v) -> ok(env, v)
                Error(msg) -> err(env, "open: " <> msg)
              }
            False -> ok(env, String(content))
          }
      }
    }
    _ -> err(env, "open: expected path")
  }
}

fn cmd_save(
  env: Env,
  input: Value,
  args: List(Value),
  _flags: dict.Dict(String, Value),
) -> BuiltinResult {
  case args {
    [String(path)] -> {
      let path = resolve_path(env, path)
      let body = case input {
        String(s) -> s
        other -> value.as_string(other)
      }
      case simplifile.write(to: path, contents: body) {
        Ok(Nil) -> ok(env, Nothing)
        Error(e) -> err(env, "save: " <> simplifile.describe_error(e))
      }
    }
    _ -> err(env, "save: expected path")
  }
}

// --- table ops ---

fn cmd_where(
  env: Env,
  input: Value,
  args: List(Value),
  _flags: dict.Dict(String, Value),
) -> BuiltinResult {
  case args {
    [String(field), String(op), rhs] -> {
      case value.table_to_records(input) {
        Error(e) -> err(env, "where: " <> e)
        Ok(rows) -> {
          let kept =
            list.filter(rows, fn(row) { row_matches(row, field, op, rhs) })
          ok(env, value.table_from_records(kept))
        }
      }
    }
    _ ->
      err(env, "where: expected `where <field> <op> <value>` e.g. type == file")
  }
}

fn row_matches(row: Value, field: String, op: String, rhs: Value) -> Bool {
  case value.get_field(row, field) {
    Error(_) -> False
    Ok(lhs) ->
      case op {
        "==" | "eq" -> value.equals(lhs, rhs)
        "!=" | "ne" -> !value.equals(lhs, rhs)
        ">" | "gt" ->
          case value.compare(lhs, rhs) {
            Ok(value.Gt) -> True
            _ -> False
          }
        "<" | "lt" ->
          case value.compare(lhs, rhs) {
            Ok(value.Lt) -> True
            _ -> False
          }
        ">=" | "ge" ->
          case value.compare(lhs, rhs) {
            Ok(value.Gt) | Ok(value.Eq) -> True
            _ -> False
          }
        "<=" | "le" ->
          case value.compare(lhs, rhs) {
            Ok(value.Lt) | Ok(value.Eq) -> True
            _ -> False
          }
        _ -> False
      }
  }
}

// --- find (Nushell-style search filter) ---

fn cmd_find(
  env: Env,
  input: Value,
  args: List(Value),
  flags: dict.Dict(String, Value),
) -> BuiltinResult {
  // Boolean flags may steal the next word (`find -i hello` → flag i = "hello").
  let #(ignore_case, stolen_i) =
    find_bool_flag(flags, ["i", "ignore-case"])
  let #(invert, stolen_v) = find_bool_flag(flags, ["v", "invert"])
  let #(multiline, stolen_m) = find_bool_flag(flags, ["m", "multiline"])
  let #(_, stolen_n) = find_bool_flag(flags, ["n", "no-highlight"])
  let #(_, stolen_s) = find_bool_flag(flags, ["s", "dotall"])
  let #(_, stolen_rfind) = find_bool_flag(flags, ["R", "rfind"])

  let regex_opt = find_regex_pattern(flags)
  let columns = find_columns(flags)

  let terms =
    list.flatten([
      args,
      stolen_i,
      stolen_v,
      stolen_m,
      stolen_n,
      stolen_s,
      stolen_rfind,
    ])

  case terms, regex_opt {
    [], option.None ->
      err(env, "find: expected search term(s) or --regex <pattern>")
    _, option.Some(Error(msg)) -> err(env, "find: " <> msg)
    [_, ..], option.Some(Ok(_)) ->
      err(env, "find: cannot use --regex with additional search terms")
    terms, regex_opt -> {
      let pattern = case regex_opt {
        option.Some(Ok(p)) -> option.Some(p)
        _ -> option.None
      }
      case
        find_filter(
          input,
          terms,
          pattern,
          ignore_case,
          invert,
          multiline,
          columns,
        )
      {
        Ok(v) -> ok(env, v)
        Error(msg) -> err(env, "find: " <> msg)
      }
    }
  }
}

/// Parse a boolean flag that may have stolen a following value as its arg.
/// Returns `(flag_set, stolen_terms)`.
fn find_bool_flag(
  flags: dict.Dict(String, Value),
  names: List(String),
) -> #(Bool, List(Value)) {
  list.fold(names, #(False, []), fn(acc, name) {
    let #(_set, stolen) = acc
    case dict.get(flags, name) {
      Error(Nil) -> acc
      Ok(Bool(False)) | Ok(Nothing) -> acc
      Ok(Bool(True)) -> #(True, stolen)
      Ok(v) -> #(True, list.append(stolen, [v]))
    }
  })
}

fn find_regex_pattern(
  flags: dict.Dict(String, Value),
) -> option.Option(Result(String, String)) {
  case dict.get(flags, "regex"), dict.get(flags, "r") {
    Ok(String(p)), _ -> option.Some(Ok(p))
    _, Ok(String(p)) -> option.Some(Ok(p))
    Ok(Bool(True)), _ | _, Ok(Bool(True)) ->
      option.Some(Error("regex flag requires a pattern (try `find --regex <pat>`)"))
    Ok(other), _ ->
      option.Some(Ok(value.as_string(other)))
    _, Ok(other) -> option.Some(Ok(value.as_string(other)))
    Error(Nil), Error(Nil) -> option.None
  }
}

fn find_columns(flags: dict.Dict(String, Value)) -> option.Option(List(String)) {
  case dict.get(flags, "columns"), dict.get(flags, "c") {
    Ok(v), _ -> columns_from_value(v)
    _, Ok(v) -> columns_from_value(v)
    Error(Nil), Error(Nil) -> option.None
  }
}

fn columns_from_value(v: Value) -> option.Option(List(String)) {
  case v {
    List(items) -> {
      let cols =
        list.filter_map(items, fn(item) {
          case item {
            String(s) -> Ok(s)
            other -> Ok(value.as_string(other))
          }
        })
      option.Some(cols)
    }
    String(s) -> option.Some([s])
    _ -> option.Some([value.as_string(v)])
  }
}

fn find_filter(
  input: Value,
  terms: List(Value),
  regex: option.Option(String),
  ignore_case: Bool,
  invert: Bool,
  multiline: Bool,
  columns: option.Option(List(String)),
) -> Result(Value, String) {
  case input {
    List(items) -> {
      case filter_items(items, terms, regex, ignore_case, invert, columns) {
        Ok(kept) -> Ok(List(kept))
        Error(e) -> Error(e)
      }
    }
    Table(_, _) ->
      case value.table_to_records(input) {
        Error(e) -> Error(e)
        Ok(rows) ->
          case filter_items(rows, terms, regex, ignore_case, invert, columns) {
            Ok(kept) -> Ok(value.table_from_records(kept))
            Error(e) -> Error(e)
          }
      }
    String(s) ->
      case multiline || !string.contains(s, "\n") {
        True ->
          case item_matches(String(s), terms, regex, ignore_case, option.None) {
            Error(e) -> Error(e)
            Ok(matched) ->
              case matched != invert {
                True -> Ok(String(s))
                False -> Ok(Nothing)
              }
          }
        False -> {
          let lines = list.map(string.split(s, "\n"), String)
          case filter_items(lines, terms, regex, ignore_case, invert, option.None) {
            Ok(kept) -> Ok(List(kept))
            Error(e) -> Error(e)
          }
        }
      }
    Nothing -> Error("pipeline input is required (try `ls | find term`)")
    other ->
      // Single scalar / record: keep if it matches, else nothing.
      case item_matches(other, terms, regex, ignore_case, columns) {
        Error(e) -> Error(e)
        Ok(matched) ->
          case matched != invert {
            True -> Ok(other)
            False -> Ok(Nothing)
          }
      }
  }
}

fn filter_items(
  items: List(Value),
  terms: List(Value),
  regex: option.Option(String),
  ignore_case: Bool,
  invert: Bool,
  columns: option.Option(List(String)),
) -> Result(List(Value), String) {
  list.try_fold(items, [], fn(acc, item) {
    case item_matches(item, terms, regex, ignore_case, columns) {
      Error(e) -> Error(e)
      Ok(matched) ->
        case matched != invert {
          True -> Ok(list.append(acc, [item]))
          False -> Ok(acc)
        }
    }
  })
}

fn item_matches(
  item: Value,
  terms: List(Value),
  regex: option.Option(String),
  ignore_case: Bool,
  columns: option.Option(List(String)),
) -> Result(Bool, String) {
  case item {
    Record(fields) -> {
      let fields = case columns {
        option.None -> fields
        option.Some(cols) ->
          list.filter(fields, fn(pair) {
            let #(k, _) = pair
            list.contains(cols, k)
          })
      }
      // Match if any selected field matches (OR), or exact record equality.
      case list.any(terms, fn(t) { value.equals(item, t) }) {
        True -> Ok(True)
        False ->
          list.try_fold(fields, False, fn(acc, pair) {
            case acc {
              True -> Ok(True)
              False -> {
                let #(_, v) = pair
                item_matches(v, terms, regex, ignore_case, option.None)
              }
            }
          })
      }
    }
    List(inner) -> {
      // Nested list: match if any element matches, or the rendered text does.
      case
        list.try_fold(inner, False, fn(acc, v) {
          case acc {
            True -> Ok(True)
            False -> item_matches(v, terms, regex, ignore_case, option.None)
          }
        })
      {
        Error(e) -> Error(e)
        Ok(True) -> Ok(True)
        Ok(False) ->
          text_matches(value.as_string(item), terms, regex, ignore_case)
      }
    }
    // Scalars: exact equality always; strings also allow substring contains.
    // Numbers/bools do not substring-match (Nu: `find 5` does not keep 35).
    String(s) -> text_matches(s, terms, regex, ignore_case)
    Int(_) | Float(_) | Bool(_) -> scalar_matches(item, terms, regex, ignore_case)
    Nothing -> scalar_matches(item, terms, regex, ignore_case)
    other -> {
      case list.any(terms, fn(t) { value.equals(other, t) }) {
        True -> Ok(True)
        False -> text_matches(value.as_string(other), terms, regex, ignore_case)
      }
    }
  }
}

fn scalar_matches(
  scalar: Value,
  terms: List(Value),
  regex: option.Option(String),
  ignore_case: Bool,
) -> Result(Bool, String) {
  case regex {
    option.Some(pattern) ->
      text_matches(
        value.as_string(scalar),
        terms,
        option.Some(pattern),
        ignore_case,
      )
    option.None -> Ok(list.any(terms, fn(t) { value.equals(scalar, t) }))
  }
}

fn text_matches(
  text: String,
  terms: List(Value),
  regex: option.Option(String),
  ignore_case: Bool,
) -> Result(Bool, String) {
  case regex {
    option.Some(pattern) ->
      case sys.re_contains(text, pattern, ignore_case) {
        Ok(b) -> Ok(b)
        Error(msg) -> Error("invalid regex: " <> msg)
      }
    option.None -> {
      let haystack = case ignore_case {
        True -> string.lowercase(text)
        False -> text
      }
      Ok(
        list.any(terms, fn(term) {
          let needle = case ignore_case {
            True -> string.lowercase(value.as_string(term))
            False -> value.as_string(term)
          }
          case needle {
            "" -> True
            _ -> string.contains(haystack, needle)
          }
        }),
      )
    }
  }
}

fn cmd_select(
  env: Env,
  input: Value,
  args: List(Value),
  _flags: dict.Dict(String, Value),
) -> BuiltinResult {
  let cols =
    list.filter_map(args, fn(a) {
      case a {
        String(s) -> Ok(s)
        _ -> Error(Nil)
      }
    })
  case cols {
    [] -> err(env, "select: expected column names")
    cols ->
      case value.table_to_records(input) {
        Error(e) -> err(env, "select: " <> e)
        Ok(rows) -> {
          let selected =
            list.map(rows, fn(row) {
              case row {
                Record(fields) ->
                  Record(
                    list.map(cols, fn(c) {
                      case list.key_find(fields, c) {
                        Ok(v) -> #(c, v)
                        Error(Nil) -> #(c, Nothing)
                      }
                    }),
                  )
                other -> other
              }
            })
          ok(env, value.table_from_records(selected))
        }
      }
  }
}

fn cmd_get(
  env: Env,
  input: Value,
  args: List(Value),
  _flags: dict.Dict(String, Value),
) -> BuiltinResult {
  case args {
    [Int(i)] -> {
      let rows = value.as_rows(input)
      case list_at(rows, i) {
        Ok(v) -> ok(env, v)
        Error(Nil) -> err(env, "get: index out of bounds")
      }
    }
    [String(key)] ->
      case input {
        Record(_) ->
          case value.get_field(input, key) {
            Ok(v) -> ok(env, v)
            Error(e) -> err(env, "get: " <> e)
          }
        Table(cols, rows) ->
          case list_index_of(cols, key) {
            Ok(idx) -> {
              let col_vals =
                list.map(rows, fn(row) {
                  case list_at(row, idx) {
                    Ok(v) -> v
                    Error(Nil) -> Nothing
                  }
                })
              ok(env, List(col_vals))
            }
            Error(Nil) -> err(env, "get: no column '" <> key <> "'")
          }
        List(items) -> {
          let got =
            list.filter_map(items, fn(item) {
              case value.get_field(item, key) {
                Ok(v) -> Ok(v)
                Error(_) -> Error(Nil)
              }
            })
          ok(env, List(got))
        }
        _ -> err(env, "get: unsupported input type " <> value.type_name(input))
      }
    _ -> err(env, "get: expected field name or index")
  }
}

fn cmd_first(
  env: Env,
  input: Value,
  args: List(Value),
  _flags: dict.Dict(String, Value),
) -> BuiltinResult {
  let n = case args {
    [Int(i)] if i > 0 -> i
    _ -> 1
  }
  take_n(env, input, n, False)
}

fn cmd_last(
  env: Env,
  input: Value,
  args: List(Value),
  _flags: dict.Dict(String, Value),
) -> BuiltinResult {
  let n = case args {
    [Int(i)] if i > 0 -> i
    _ -> 1
  }
  take_n(env, input, n, True)
}

fn cmd_take(
  env: Env,
  input: Value,
  args: List(Value),
  _flags: dict.Dict(String, Value),
) -> BuiltinResult {
  case args {
    [Int(n)] -> take_n(env, input, n, False)
    _ -> err(env, "take: expected count")
  }
}

fn take_n(env: Env, input: Value, n: Int, from_end: Bool) -> BuiltinResult {
  case input {
    Table(cols, rows) -> {
      let rows = case from_end {
        True -> rows |> list.reverse |> list.take(n) |> list.reverse
        False -> list.take(rows, n)
      }
      case n == 1 {
        True ->
          case rows {
            [row] -> ok(env, Record(list.zip(cols, row)))
            _ -> ok(env, Table(cols, rows))
          }
        False -> ok(env, Table(cols, rows))
      }
    }
    List(items) -> {
      let items = case from_end {
        True -> items |> list.reverse |> list.take(n) |> list.reverse
        False -> list.take(items, n)
      }
      case n == 1 {
        True ->
          case items {
            [x] -> ok(env, x)
            _ -> ok(env, List(items))
          }
        False -> ok(env, List(items))
      }
    }
    String(s) -> {
      let graphemes = string.to_graphemes(s)
      let taken = case from_end {
        True -> graphemes |> list.reverse |> list.take(n) |> list.reverse
        False -> list.take(graphemes, n)
      }
      ok(env, String(string.concat(taken)))
    }
    other -> ok(env, other)
  }
}

fn cmd_skip(
  env: Env,
  input: Value,
  args: List(Value),
  _flags: dict.Dict(String, Value),
) -> BuiltinResult {
  case args {
    [Int(n)] ->
      case input {
        Table(cols, rows) -> ok(env, Table(cols, list.drop(rows, n)))
        List(items) -> ok(env, List(list.drop(items, n)))
        other -> ok(env, other)
      }
    _ -> err(env, "skip: expected count")
  }
}

fn cmd_length(
  env: Env,
  input: Value,
  _args: List(Value),
  _flags: dict.Dict(String, Value),
) -> BuiltinResult {
  ok(env, Int(value.length_of(input)))
}

fn cmd_reverse(
  env: Env,
  input: Value,
  _args: List(Value),
  _flags: dict.Dict(String, Value),
) -> BuiltinResult {
  case input {
    List(items) -> ok(env, List(list.reverse(items)))
    Table(cols, rows) -> ok(env, Table(cols, list.reverse(rows)))
    String(s) ->
      ok(
        env,
        String(
          s
          |> string.to_graphemes
          |> list.reverse
          |> string.concat,
        ),
      )
    other -> ok(env, other)
  }
}

fn cmd_sort_by(
  env: Env,
  input: Value,
  args: List(Value),
  _flags: dict.Dict(String, Value),
) -> BuiltinResult {
  case args {
    [String(field)] ->
      case value.table_to_records(input) {
        Error(e) -> err(env, "sort-by: " <> e)
        Ok(rows) -> {
          let sorted =
            list.sort(rows, fn(a, b) {
              let va = case value.get_field(a, field) {
                Ok(v) -> v
                Error(_) -> Nothing
              }
              let vb = case value.get_field(b, field) {
                Ok(v) -> v
                Error(_) -> Nothing
              }
              case value.compare(va, vb) {
                Ok(value.Lt) -> order.Lt
                Ok(value.Gt) -> order.Gt
                Ok(value.Eq) -> order.Eq
                Error(_) ->
                  string.compare(value.as_string(va), value.as_string(vb))
              }
            })
          ok(env, value.table_from_records(sorted))
        }
      }
    _ -> err(env, "sort-by: expected field name")
  }
}

fn cmd_uniq(
  env: Env,
  input: Value,
  _args: List(Value),
  _flags: dict.Dict(String, Value),
) -> BuiltinResult {
  case input {
    List(items) -> {
      let uniqed =
        list.fold(items, [], fn(acc, item) {
          case list.any(acc, fn(x) { value.equals(x, item) }) {
            True -> acc
            False -> list.append(acc, [item])
          }
        })
      ok(env, List(uniqed))
    }
    other -> ok(env, other)
  }
}

fn cmd_wrap(
  env: Env,
  input: Value,
  args: List(Value),
  _flags: dict.Dict(String, Value),
) -> BuiltinResult {
  case args {
    [String(name)] -> ok(env, Record([#(name, input)]))
    _ -> err(env, "wrap: expected column name")
  }
}

fn cmd_unwrap(
  env: Env,
  input: Value,
  args: List(Value),
  _flags: dict.Dict(String, Value),
) -> BuiltinResult {
  case args {
    [String(name)] ->
      case value.get_field(input, name) {
        Ok(v) -> ok(env, v)
        Error(e) -> err(env, "unwrap: " <> e)
      }
    [] ->
      case input {
        Record([#(_, v), ..]) -> ok(env, v)
        _ -> err(env, "unwrap: expected single-field record or field name")
      }
    _ -> err(env, "unwrap: expected field name")
  }
}

// --- to / from (Nushell-style format commands with subcommands) ---

fn cmd_to(
  env: Env,
  input: Value,
  args: List(Value),
  flags: dict.Dict(String, Value),
) -> BuiltinResult {
  case args {
    [String("json"), ..rest] -> cmd_to_json(env, input, rest, flags)
    [] ->
      err(env, "to: expected subcommand (try `to json`; see `help to`)")
    [String(sub), ..] -> err(env, "to: unknown subcommand: " <> sub)
    _ -> err(env, "to: expected subcommand name")
  }
}

fn cmd_from(
  env: Env,
  input: Value,
  args: List(Value),
  flags: dict.Dict(String, Value),
) -> BuiltinResult {
  case args {
    [String("json"), ..rest] -> cmd_from_json(env, input, rest, flags)
    [] ->
      err(env, "from: expected subcommand (try `from json`; see `help from`)")
    [String(sub), ..] -> err(env, "from: unknown subcommand: " <> sub)
    _ -> err(env, "from: expected subcommand name")
  }
}

fn cmd_to_json(
  env: Env,
  input: Value,
  _args: List(Value),
  flags: dict.Dict(String, Value),
) -> BuiltinResult {
  // Default: pretty-print with 2-space indent (like Nu). `--raw` / `-r` is compact.
  let raw = flag_set(flags, "raw") || flag_set(flags, "r")
  let indent = case raw {
    True -> option.None
    False ->
      case flag_int(flags, "indent") {
        option.Some(n) -> option.Some(n)
        option.None ->
          case flag_int(flags, "i") {
            option.Some(n) -> option.Some(n)
            option.None -> option.Some(2)
          }
      }
  }
  let body = encode_json(input, indent, 0)
  // Nu's default includes a trailing newline; `--raw` omits it.
  let text = case indent {
    option.None -> body
    option.Some(_) -> body <> "\n"
  }
  ok(env, String(text))
}

fn cmd_from_json(
  env: Env,
  input: Value,
  args: List(Value),
  _flags: dict.Dict(String, Value),
) -> BuiltinResult {
  let source = case args {
    [String(s)] -> s
    [] ->
      case input {
        String(s) -> s
        _ -> value.as_string(input)
      }
    _ -> ""
  }
  case source {
    "" -> err(env, "from: json: empty input")
    s ->
      case parse_json_value(s) {
        Ok(v) -> ok(env, v)
        Error(msg) -> err(env, "from: json: " <> msg)
      }
  }
}

// --- http (Nushell-style HTTP client with method subcommands) ---

fn http_help_text() -> String {
  string.join(
    [
      "http <method> <url> [body] — make an HTTP request",
      "",
      "Subcommands:",
      "  get <url>              GET request",
      "  post <url> [body]      POST (body from arg or pipeline input)",
      "  put <url> [body]       PUT",
      "  delete <url> [body]    DELETE",
      "  patch <url> [body]     PATCH",
      "  head <url>             HEAD (headers only)",
      "",
      "Flags:",
      "  -H, --headers <record|string>  request headers (record or \"Name: value\")",
      "  -t, --content-type <type>      Content-Type for the body",
      "  -u, --user <name>              basic-auth username",
      "  -p, --password <pass>          basic-auth password",
      "  -m, --max-time <secs>          response timeout in seconds (default 30)",
      "  -k, --insecure                 skip TLS certificate verification",
      "  -r, --raw                      keep body as text (do not parse JSON)",
      "  -f, --full                     return {status, headers, body, url}",
      "  -e, --allow-errors             do not fail on non-2xx status",
      "",
      "JSON responses are parsed into structured data unless --raw is set.",
      "Structured request bodies (records/lists/tables) are JSON-encoded and",
      "sent with Content-Type: application/json when no type is specified.",
      "",
      "Examples:",
      "  http get https://example.com",
      "  http get --full https://httpbin.org/get",
      "  http post https://httpbin.org/post {name: alice}",
      "  http get -H {accept: application/json} https://api.example.com/v1",
      "  echo {x: 1} | http post https://httpbin.org/post",
    ],
    "\n",
  )
}

fn cmd_http(
  env: Env,
  input: Value,
  args: List(Value),
  flags: dict.Dict(String, Value),
) -> BuiltinResult {
  case args {
    [] ->
      err(
        env,
        "http: expected subcommand (try `http get <url>`; see `help http`)",
      )
    [String(sub), ..rest] ->
      case http_method_from_sub(sub) {
        Ok(method) -> http_request(env, input, method, rest, flags)
        Error(Nil) -> err(env, "http: unknown subcommand: " <> sub)
      }
    _ -> err(env, "http: expected subcommand name")
  }
}

fn http_method_from_sub(sub: String) -> Result(http.Method, Nil) {
  case string.lowercase(sub) {
    "get" -> Ok(http.Get)
    "post" -> Ok(http.Post)
    "put" -> Ok(http.Put)
    "delete" -> Ok(http.Delete)
    "patch" -> Ok(http.Patch)
    "head" -> Ok(http.Head)
    _ -> Error(Nil)
  }
}

fn http_request(
  env: Env,
  input: Value,
  method: http.Method,
  args: List(Value),
  flags: dict.Dict(String, Value),
) -> BuiltinResult {
  let method_name = http.method_to_string(method)
  // Boolean flags may steal the next word as their value
  // (`http get --full https://…` → flag full = "https://…").
  let #(_full, stolen_f) = find_bool_flag(flags, ["full", "f"])
  let #(_raw, stolen_r) = find_bool_flag(flags, ["raw", "r"])
  let #(_insecure, stolen_k) = find_bool_flag(flags, ["insecure", "k"])
  let #(_allow, stolen_e) = find_bool_flag(flags, ["allow-errors", "e"])
  let candidates =
    list.flatten([args, stolen_f, stolen_r, stolen_k, stolen_e])
  case http_take_url(candidates) {
    Error(Nil) -> err(env, "http: " <> method_name <> ": expected URL")
    Ok(#(url, body_args)) ->
      case string.trim(url) {
        "" -> err(env, "http: " <> method_name <> ": empty URL")
        url ->
          case request.to(url) {
            Error(Nil) ->
              err(env, "http: " <> method_name <> ": invalid URL: " <> url)
            Ok(base) -> {
              let body_opt = http_resolve_body(method, input, body_args)
              let #(body_text, auto_json) = case body_opt {
                option.None -> #("", False)
                option.Some(body) -> http_encode_body(body)
              }
              let req =
                base
                |> request.set_method(method)
                |> request.set_body(body_text)
                |> http_apply_headers(flags, auto_json)
                |> http_apply_auth(flags)
              let config = http_config(flags)
              case httpc.dispatch(config, req) {
                Error(e) ->
                  err(
                    env,
                    "http: " <> method_name <> ": " <> http_error_message(e),
                  )
                Ok(resp) ->
                  http_handle_response(env, method_name, url, resp, flags)
              }
            }
          }
      }
  }
}

/// Pick a URL from mixed positionals + values stolen by boolean flags.
/// Prefers a URL-shaped string (`http(s)://…`); otherwise the first value.
fn http_take_url(
  values: List(Value),
) -> Result(#(String, List(Value)), Nil) {
  case values {
    [] -> Error(Nil)
    _ ->
      case http_find_url_index(values, 0) {
        option.Some(i) -> {
          let url = case list_at(values, i) {
            Ok(v) -> value.as_string(v)
            Error(Nil) -> ""
          }
          let rest =
            values
            |> list.index_map(fn(v, idx) { #(idx, v) })
            |> list.filter_map(fn(pair) {
              let #(idx, v) = pair
              case idx == i {
                True -> Error(Nil)
                False -> Ok(v)
              }
            })
          Ok(#(url, rest))
        }
        option.None ->
          case values {
            [first, ..rest] -> Ok(#(value.as_string(first), rest))
            [] -> Error(Nil)
          }
      }
  }
}

fn http_find_url_index(
  values: List(Value),
  index: Int,
) -> option.Option(Int) {
  case values {
    [] -> option.None
    [v, ..rest] ->
      case v {
        String(s) ->
          case http_looks_like_url(s) {
            True -> option.Some(index)
            False -> http_find_url_index(rest, index + 1)
          }
        _ -> http_find_url_index(rest, index + 1)
      }
  }
}

fn http_looks_like_url(s: String) -> Bool {
  string.starts_with(s, "http://")
  || string.starts_with(s, "https://")
  || string.contains(s, "://")
}

fn http_resolve_body(
  method: http.Method,
  input: Value,
  body_args: List(Value),
) -> option.Option(Value) {
  case method {
    http.Get | http.Head -> option.None
    _ ->
      case body_args {
        [body, ..] -> option.Some(body)
        [] ->
          case input {
            Nothing -> option.None
            Fail(_) -> option.None
            _ -> option.Some(input)
          }
      }
  }
}

/// Encode a body value. Returns `(text, is_json_structured)`.
fn http_encode_body(body: Value) -> #(String, Bool) {
  case body {
    String(s) -> #(s, False)
    Nothing -> #("", False)
    other -> #(encode_json(other, option.None, 0), True)
  }
}

fn http_apply_headers(
  req: request.Request(String),
  flags: dict.Dict(String, Value),
  auto_json: Bool,
) -> request.Request(String) {
  let req = case auto_json {
    True ->
      case http_flag_string(flags, ["content-type", "t"]) {
        option.Some(_) -> req
        option.None ->
          request.set_header(req, "content-type", "application/json")
      }
    False -> req
  }
  let req = case http_flag_string(flags, ["content-type", "t"]) {
    option.Some(ct) -> request.set_header(req, "content-type", ct)
    option.None -> req
  }
  case http_flag_value(flags, ["headers", "H"]) {
    option.None -> req
    option.Some(headers_val) ->
      list.fold(http_parse_headers(headers_val), req, fn(acc, pair) {
        let #(k, v) = pair
        request.set_header(acc, string.lowercase(k), v)
      })
  }
}

fn http_parse_headers(val: Value) -> List(#(String, String)) {
  case val {
    Record(fields) ->
      list.map(fields, fn(pair) {
        let #(k, v) = pair
        #(k, value.as_string(v))
      })
    List(items) ->
      list.flat_map(items, fn(item) {
        case item {
          String(s) -> http_parse_header_line(s)
          Record(fields) ->
            list.map(fields, fn(pair) {
              let #(k, v) = pair
              #(k, value.as_string(v))
            })
          _ -> []
        }
      })
    String(s) -> http_parse_header_line(s)
    _ -> []
  }
}

fn http_parse_header_line(s: String) -> List(#(String, String)) {
  case string.split_once(s, ":") {
    Ok(#(name, rest)) -> [#(string.trim(name), string.trim(rest))]
    Error(Nil) ->
      case string.trim(s) {
        "" -> []
        _ -> [#(string.trim(s), "")]
      }
  }
}

fn http_apply_auth(
  req: request.Request(String),
  flags: dict.Dict(String, Value),
) -> request.Request(String) {
  case http_flag_string(flags, ["user", "u"]) {
    option.None -> req
    option.Some(user) -> {
      let pass = case http_flag_string(flags, ["password", "p"]) {
        option.Some(p) -> p
        option.None -> ""
      }
      let token =
        bit_array.base64_encode(bit_array.from_string(user <> ":" <> pass), True)
      request.set_header(req, "authorization", "Basic " <> token)
    }
  }
}

fn http_config(flags: dict.Dict(String, Value)) -> httpc.Configuration {
  let insecure =
    flag_set(flags, "insecure") || flag_set(flags, "k")
  let timeout_ms = case http_flag_int(flags, ["max-time", "m"]) {
    option.Some(secs) if secs > 0 -> secs * 1000
    _ -> 30_000
  }
  httpc.configure()
  |> httpc.verify_tls(!insecure)
  |> httpc.timeout(timeout_ms)
  |> httpc.follow_redirects(True)
}

fn http_handle_response(
  env: Env,
  method_name: String,
  url: String,
  resp: response.Response(String),
  flags: dict.Dict(String, Value),
) -> BuiltinResult {
  let raw = flag_set(flags, "raw") || flag_set(flags, "r")
  let full = flag_set(flags, "full") || flag_set(flags, "f")
  let allow_errors =
    flag_set(flags, "allow-errors") || flag_set(flags, "e")
  let body_val = case raw {
    True -> String(resp.body)
    False -> http_decode_body(resp)
  }
  let headers_record =
    Record(
      list.map(resp.headers, fn(pair) {
        let #(k, v) = pair
        #(k, String(v))
      }),
    )
  let ok_status = resp.status >= 200 && resp.status < 300
  case full {
    True -> {
      let result =
        Record([
          #("status", Int(resp.status)),
          #("headers", headers_record),
          #("body", body_val),
          #("url", String(url)),
        ])
      case ok_status || allow_errors {
        True -> ok(env, result)
        False ->
          err(
            env,
            "http: "
              <> method_name
              <> ": HTTP "
              <> int.to_string(resp.status)
              <> " from "
              <> url,
          )
      }
    }
    False ->
      case ok_status || allow_errors {
        True -> ok(env, body_val)
        False ->
          err(
            env,
            "http: "
              <> method_name
              <> ": HTTP "
              <> int.to_string(resp.status)
              <> " from "
              <> url
              <> case string.trim(resp.body) {
                "" -> ""
                body -> ": " <> string.slice(body, 0, 200)
              },
          )
      }
  }
}

fn http_decode_body(resp: response.Response(String)) -> Value {
  let looks_json = case response.get_header(resp, "content-type") {
    Ok(ct) -> {
      let lower = string.lowercase(ct)
      string.contains(lower, "json") || string.contains(lower, "+json")
    }
    Error(Nil) -> False
  }
  let trimmed = string.trim(resp.body)
  case looks_json || string.starts_with(trimmed, "{") || string.starts_with(
    trimmed,
    "[",
  ) {
    True ->
      case parse_json_value(resp.body) {
        Ok(v) -> v
        Error(_) -> String(resp.body)
      }
    False -> String(resp.body)
  }
}

fn http_error_message(e: httpc.HttpError) -> String {
  case e {
    httpc.InvalidUtf8Response -> "response body is not valid UTF-8"
    httpc.ResponseTimeout -> "response timed out"
    httpc.FailedToConnect(ip4, ip6) ->
      "failed to connect ("
      <> http_connect_error(ip4)
      <> " / "
      <> http_connect_error(ip6)
      <> ")"
  }
}

fn http_connect_error(e: httpc.ConnectError) -> String {
  case e {
    httpc.Posix(code) -> code
    httpc.TlsAlert(code, detail) -> code <> ": " <> detail
  }
}

fn http_flag_value(
  flags: dict.Dict(String, Value),
  names: List(String),
) -> option.Option(Value) {
  case names {
    [] -> option.None
    [name, ..rest] ->
      case dict.get(flags, name) {
        Ok(v) -> option.Some(v)
        Error(Nil) -> http_flag_value(flags, rest)
      }
  }
}

fn http_flag_string(
  flags: dict.Dict(String, Value),
  names: List(String),
) -> option.Option(String) {
  case http_flag_value(flags, names) {
    option.Some(String(s)) -> option.Some(s)
    option.Some(v) -> option.Some(value.as_string(v))
    option.None -> option.None
  }
}

fn http_flag_int(
  flags: dict.Dict(String, Value),
  names: List(String),
) -> option.Option(Int) {
  case http_flag_value(flags, names) {
    option.Some(Int(n)) -> option.Some(n)
    option.Some(String(s)) ->
      case int.parse(s) {
        Ok(n) -> option.Some(n)
        Error(Nil) -> option.None
      }
    _ -> option.None
  }
}

fn flag_set(flags: dict.Dict(String, Value), name: String) -> Bool {
  case dict.get(flags, name) {
    Ok(Bool(False)) -> False
    Ok(Nothing) -> False
    Ok(_) -> True
    Error(Nil) -> False
  }
}

fn flag_int(flags: dict.Dict(String, Value), name: String) -> option.Option(Int) {
  case dict.get(flags, name) {
    Ok(Int(n)) -> option.Some(n)
    _ -> option.None
  }
}

/// Encode a value as JSON. `indent` is `None` for compact (`--raw`), or
/// `Some(n)` for n-space pretty-print (Nushell default is 2).
fn encode_json(v: Value, indent: option.Option(Int), depth: Int) -> String {
  case v {
    Nothing -> "null"
    Bool(True) -> "true"
    Bool(False) -> "false"
    Int(n) -> int.to_string(n)
    Float(f) -> float.to_string(f)
    String(s) -> json_escape(s)
    List(items) -> encode_json_array(items, indent, depth)
    Record(fields) -> encode_json_object(fields, indent, depth)
    Table(cols, rows) -> {
      let records = list.map(rows, fn(row) { Record(list.zip(cols, row)) })
      encode_json(List(records), indent, depth)
    }
    Fail(msg) -> json_escape("error: " <> msg)
  }
}

fn encode_json_array(
  items: List(Value),
  indent: option.Option(Int),
  depth: Int,
) -> String {
  case items {
    [] -> "[]"
    _ ->
      case indent {
        option.None ->
          "["
          <> string.join(list.map(items, fn(i) { encode_json(i, indent, 0) }), ",")
          <> "]"
        option.Some(width) -> {
          let inner = depth + 1
          let pad = string.repeat(" ", width * inner)
          let close = string.repeat(" ", width * depth)
          let body =
            items
            |> list.map(fn(i) { pad <> encode_json(i, indent, inner) })
            |> string.join(",\n")
          "[\n" <> body <> "\n" <> close <> "]"
        }
      }
  }
}

fn encode_json_object(
  fields: List(#(String, Value)),
  indent: option.Option(Int),
  depth: Int,
) -> String {
  case fields {
    [] -> "{}"
    _ ->
      case indent {
        option.None ->
          "{"
          <> string.join(
            list.map(fields, fn(pair) {
              let #(k, val) = pair
              json_escape(k) <> ":" <> encode_json(val, indent, 0)
            }),
            ",",
          )
          <> "}"
        option.Some(width) -> {
          let inner = depth + 1
          let pad = string.repeat(" ", width * inner)
          let close = string.repeat(" ", width * depth)
          let body =
            fields
            |> list.map(fn(pair) {
              let #(k, val) = pair
              pad
              <> json_escape(k)
              <> ": "
              <> encode_json(val, indent, inner)
            })
            |> string.join(",\n")
          "{\n" <> body <> "\n" <> close <> "}"
        }
      }
  }
}

fn json_escape(s: String) -> String {
  let escaped =
    s
    |> string.replace("\\", "\\\\")
    |> string.replace("\"", "\\\"")
    |> string.replace("\n", "\\n")
    |> string.replace("\r", "\\r")
    |> string.replace("\t", "\\t")
  "\"" <> escaped <> "\""
}

fn parse_json_value(source: String) -> Result(Value, String) {
  case string.trim(source) {
    "null" -> Ok(Nothing)
    s ->
      case json.parse(from: s, using: value_decoder()) {
        Ok(v) -> Ok(v)
        Error(e) -> Error(string.inspect(e))
      }
  }
}

fn value_decoder() -> decode.Decoder(Value) {
  decode.recursive(fn() {
    decode.one_of(decode.map(decode.string, String), or: [
      decode.map(decode.bool, Bool),
      decode.map(decode.int, Int),
      decode.map(decode.float, Float),
      decode.map(decode.list(value_decoder()), List),
      decode.map(decode.dict(decode.string, value_decoder()), fn(d) {
        let pairs =
          dict.to_list(d)
          |> list.sort(fn(a, b) {
            let #(ka, _) = a
            let #(kb, _) = b
            string.compare(ka, kb)
          })
        Record(pairs)
      }),
      // JSON null → optional empty
      decode.map(decode.optional(decode.int), fn(opt) {
        case opt {
          option.None -> Nothing
          option.Some(n) -> Int(n)
        }
      }),
    ])
  })
}

// --- misc ---

fn cmd_lines(
  env: Env,
  input: Value,
  _args: List(Value),
  _flags: dict.Dict(String, Value),
) -> BuiltinResult {
  case input {
    String(s) -> {
      let lines = list.map(string.split(s, "\n"), String)
      ok(env, List(lines))
    }
    _ -> err(env, "lines: expected string input")
  }
}

fn cmd_type(
  env: Env,
  input: Value,
  _args: List(Value),
  _flags: dict.Dict(String, Value),
) -> BuiltinResult {
  ok(env, String(value.type_name(input)))
}

fn cmd_describe(
  env: Env,
  input: Value,
  _args: List(Value),
  _flags: dict.Dict(String, Value),
) -> BuiltinResult {
  ok(
    env,
    Record([
      #("type", String(value.type_name(input))),
      #("length", Int(value.length_of(input))),
      #("value", String(value.as_string(input))),
    ]),
  )
}

fn cmd_env(
  env: Env,
  _input: Value,
  args: List(Value),
  _flags: dict.Dict(String, Value),
) -> BuiltinResult {
  case args {
    [String(name)] -> ok(env, env.get_var(env, "env." <> name))
    [] -> {
      // Process environment (same data as `$env`), as a name/value table
      case env.env_record(env) {
        Record(fields) -> {
          let pairs =
            list.map(fields, fn(pair) {
              let #(k, v) = pair
              Record([
                #("name", String(k)),
                #("value", String(value.as_string(v))),
              ])
            })
          ok(env, value.table_from_records(pairs))
        }
        other -> ok(env, other)
      }
    }
    _ -> err(env, "env: unexpected args (use `env` or `env NAME`)")
  }
}

fn cmd_which(
  env: Env,
  _input: Value,
  args: List(Value),
  flags: dict.Dict(String, Value),
) -> BuiltinResult {
  // Boolean flags may steal the next word (`which -a name` → flag a = "name").
  // Accept `which -a|-f name`, `which name -a|-f`, and long forms.
  let #(all, stolen_a) = find_bool_flag(flags, ["a", "all"])
  let #(follow, stolen_f) = find_bool_flag(flags, ["f", "follow"])
  let name_opt = case list.append(args, list.append(stolen_a, stolen_f)) {
    [String(n)] -> option.Some(n)
    [other] -> option.Some(value.as_string(other))
    _ -> option.None
  }
  case name_opt {
    option.Some(name) -> {
      let is_builtin = dict.has_key(registry(), name)
      case all {
        True -> {
          let paths =
            list.map(sys.which_all(name), fn(p) {
              String(which_maybe_follow(follow, p))
            })
          let matches = case is_builtin {
            True -> [String("builtin: " <> name), ..paths]
            False -> paths
          }
          case matches {
            [] -> err(env, "which: " <> name <> " not found")
            [one] -> ok(env, one)
            many -> ok(env, List(many))
          }
        }
        False ->
          case is_builtin {
            True -> ok(env, String("builtin: " <> name))
            False ->
              case sys.which(name) {
                Ok(path) -> ok(env, String(which_maybe_follow(follow, path)))
                Error(Nil) -> err(env, "which: " <> name <> " not found")
              }
          }
      }
    }
    option.None ->
      err(
        env,
        "which: expected name (try `which [-a] [-f] <name>`)",
      )
  }
}

/// With `-f`/`--follow`, resolve symlinks to a canonical absolute path.
/// On failure (broken link, loop), keep the original which path.
fn which_maybe_follow(follow: Bool, path: String) -> String {
  case follow {
    False -> path
    True ->
      case sys.realpath(path) {
        Ok(resolved) -> resolved
        Error(Nil) -> path
      }
  }
}

fn cmd_exit(
  _env: Env,
  _input: Value,
  args: List(Value),
  _flags: dict.Dict(String, Value),
) -> BuiltinResult {
  let code = case args {
    [Int(n)] -> n
    _ -> 0
  }
  Exit(code)
}

fn cmd_ignore(
  env: Env,
  _input: Value,
  _args: List(Value),
  _flags: dict.Dict(String, Value),
) -> BuiltinResult {
  ok(env, Nothing)
}

fn cmd_identity(
  env: Env,
  input: Value,
  _args: List(Value),
  _flags: dict.Dict(String, Value),
) -> BuiltinResult {
  ok(env, input)
}

fn cmd_range(
  env: Env,
  _input: Value,
  args: List(Value),
  _flags: dict.Dict(String, Value),
) -> BuiltinResult {
  case args {
    [Int(end)] -> ok(env, List(range_list(0, end)))
    [Int(start), Int(end)] -> ok(env, List(range_list(start, end)))
    _ -> err(env, "range: expected `range <end>` or `range <start> <end>`")
  }
}

fn range_list(start: Int, end: Int) -> List(Value) {
  case start >= end {
    True -> []
    False -> [Int(start), ..range_list(start + 1, end)]
  }
}

fn cmd_append(
  env: Env,
  input: Value,
  args: List(Value),
  _flags: dict.Dict(String, Value),
) -> BuiltinResult {
  case input {
    List(items) -> ok(env, List(list.append(items, args)))
    _ -> err(env, "append: expected list input")
  }
}

fn cmd_prepend(
  env: Env,
  input: Value,
  args: List(Value),
  _flags: dict.Dict(String, Value),
) -> BuiltinResult {
  case input {
    List(items) -> ok(env, List(list.append(args, items)))
    _ -> err(env, "prepend: expected list input")
  }
}

fn cmd_is_empty(
  env: Env,
  input: Value,
  _args: List(Value),
  _flags: dict.Dict(String, Value),
) -> BuiltinResult {
  ok(env, Bool(value.length_of(input) == 0))
}

fn cmd_table(
  env: Env,
  input: Value,
  _args: List(Value),
  _flags: dict.Dict(String, Value),
) -> BuiltinResult {
  case value.table_to_records(input) {
    Ok(rows) -> ok(env, value.table_from_records(rows))
    Error(e) -> err(env, "table: " <> e)
  }
}

fn cmd_columns(
  env: Env,
  input: Value,
  _args: List(Value),
  _flags: dict.Dict(String, Value),
) -> BuiltinResult {
  case input {
    Table(cols, _) -> ok(env, List(list.map(cols, String)))
    Record(fields) ->
      ok(
        env,
        List(
          list.map(fields, fn(p) {
            let #(k, _) = p
            String(k)
          }),
        ),
      )
    _ -> err(env, "columns: expected table or record")
  }
}

fn cmd_flatten(
  env: Env,
  input: Value,
  _args: List(Value),
  _flags: dict.Dict(String, Value),
) -> BuiltinResult {
  case input {
    List(items) -> {
      let flat =
        list.flat_map(items, fn(item) {
          case item {
            List(inner) -> inner
            other -> [other]
          }
        })
      ok(env, List(flat))
    }
    other -> ok(env, other)
  }
}

fn cmd_values(
  env: Env,
  input: Value,
  _args: List(Value),
  _flags: dict.Dict(String, Value),
) -> BuiltinResult {
  case input {
    Record(fields) ->
      ok(
        env,
        List(
          list.map(fields, fn(p) {
            let #(_, v) = p
            v
          }),
        ),
      )
    _ -> err(env, "values: expected record")
  }
}

fn cmd_keys(
  env: Env,
  input: Value,
  _args: List(Value),
  _flags: dict.Dict(String, Value),
) -> BuiltinResult {
  case input {
    Record(fields) ->
      ok(
        env,
        List(
          list.map(fields, fn(p) {
            let #(k, _) = p
            String(k)
          }),
        ),
      )
    _ -> err(env, "keys: expected record")
  }
}

fn cmd_sys(
  env: Env,
  _input: Value,
  _args: List(Value),
  _flags: dict.Dict(String, Value),
) -> BuiltinResult {
  let home = case sys.home_dir() {
    Ok(h) -> h
    Error(_) -> ""
  }
  ok(
    env,
    Record([
      #("cwd", String(env.cwd)),
      #("home", String(home)),
      #("shell", String("gleshell")),
      #("last_exit", Int(env.last_exit)),
    ]),
  )
}

// --- ps (Nushell-style process table) ---

fn cmd_ps(
  env: Env,
  _input: Value,
  _args: List(Value),
  flags: dict.Dict(String, Value),
) -> BuiltinResult {
  let #(long, _) = find_bool_flag(flags, ["l", "long"])
  let records =
    list.map(sys.list_processes(), fn(p) { process_to_record(p, long) })
  ok(env, value.table_from_records(records))
}

fn process_to_record(p: sys.ProcessInfo, long: Bool) -> Value {
  let base = [
    #("pid", Int(p.pid)),
    #("ppid", Int(p.ppid)),
    #("name", String(p.name)),
    #("status", String(p.status)),
    #("cpu", Float(p.cpu)),
    #("mem", Int(p.mem)),
    #("virtual", Int(p.virtual)),
  ]
  case long {
    False -> Record(base)
    True ->
      Record(
        list.append(base, [
          #("command", String(p.command)),
          #("start_time", Int(p.start_time)),
          #("user_id", Int(p.user_id)),
          #("process_group_id", Int(p.process_group_id)),
          #("session_id", Int(p.session_id)),
          #("priority", Int(p.priority)),
          #("process_threads", Int(p.process_threads)),
          #("working", Int(p.working)),
          #("paged", Int(p.paged)),
          #("cwd", String(p.cwd)),
        ]),
      )
  }
}

// --- less (color-aware pager) ---

fn cmd_less(
  env: Env,
  input: Value,
  args: List(Value),
  _flags: dict.Dict(String, Value),
) -> BuiltinResult {
  case less_content(env, input, args) {
    Error(msg) -> err(env, msg)
    Ok(text) ->
      case pager.needs_paging(text) {
        True -> {
          pager.run(text)
          ok(env, Nothing)
        }
        // Fits on one screen or not a TTY: emit the text so the REPL / -c
        // path prints it once (ANSI preserved by display.render for strings).
        False -> ok(env, String(text))
      }
  }
}

/// Build the text to page: file args win (like external less); otherwise
/// pipeline input. Raw strings (e.g. `git log` output) are kept byte-for-byte
/// so embedded ANSI is not re-painted; structured values are pretty-printed
/// with colors via `display.render`.
fn less_content(
  env: Env,
  input: Value,
  args: List(Value),
) -> Result(String, String) {
  case args {
    [] ->
      case input {
        Nothing -> Error("less: no input (pipe data or pass a file path)")
        // Do not run display.render on external text: short plain lines would
        // get string-green, and multi-line ANSI must stay exactly as emitted.
        String(s) -> Ok(s)
        other -> Ok(display.render(other))
      }
    paths -> {
      case list.try_map(paths, fn(a) {
        case a {
          String(path) -> read_less_file(env, path)
          _ -> Error("less: expected file path")
        }
      }) {
        Error(e) -> Error(e)
        Ok(parts) -> Ok(string.join(parts, "\n"))
      }
    }
  }
}

fn read_less_file(env: Env, path: String) -> Result(String, String) {
  let path = resolve_path(env, path)
  case simplifile.read(path) {
    Ok(content) -> Ok(content)
    Error(e) -> Error("less: " <> simplifile.describe_error(e))
  }
}

// --- about ---

fn cmd_about(
  env: Env,
  _input: Value,
  _args: List(Value),
  _flags: dict.Dict(String, Value),
) -> BuiltinResult {
  ok(env, String(about_text()))
}

fn about_text() -> String {
  string.join(
    [
      "          ✨ gleshell ✨",
      "   a structured-data shell in Gleam",
      "   inspired by Nushell · pipelines with types",
      "",
      "        ╱|、",
      "      (˚ˎ 。7",
      "       |、˜〵",
      "       じしˍ,)ノ  meow · you found the about page",
      "",
      "   author     NaNdi",
      "   handle     @nandi.uk",
      "   atproto    did:plc:ngokl2gnmpbvuvrfckja3g7p",
      "   web        https://latha.org",
      "   licence    Apache-2.0",
      "",
      "   \"a category is a quiver under the free functor\"",
      "",
      "   🐚  type `help` to explore · `^cmd` for externals",
      "   💜  made for people who pipe records, not just text",
    ],
    "\n",
  )
}

// --- helpers ---

fn list_at(items: List(a), index: Int) -> Result(a, Nil) {
  case items, index {
    [x, ..], 0 -> Ok(x)
    [_, ..rest], n if n > 0 -> list_at(rest, n - 1)
    _, _ -> Error(Nil)
  }
}

fn list_index_of(items: List(a), target: a) -> Result(Int, Nil) {
  list_index_of_loop(items, target, 0)
}

fn list_index_of_loop(items: List(a), target: a, i: Int) -> Result(Int, Nil) {
  case items {
    [] -> Error(Nil)
    [x, ..rest] ->
      case x == target {
        True -> Ok(i)
        False -> list_index_of_loop(rest, target, i + 1)
      }
  }
}
