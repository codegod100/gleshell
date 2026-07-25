//// Built-in commands (Nushell-inspired structured data tools).

import filepath
import gleam/dict
import gleam/dynamic/decode
import gleam/float
import gleam/int
import gleam/json
import gleam/list
import gleam/option
import gleam/order
import gleam/string
import gleshell/env.{type Env}
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
    #("to-json", cmd_to_json),
    #("to_json", cmd_to_json),
    #("from-json", cmd_from_json),
    #("from_json", cmd_from_json),
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
  ])
}

pub fn names() -> List(String) {
  registry()
  |> dict.keys
  |> list.sort(string.compare)
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
      case dict.get(help_text(), name) {
        Ok(text) -> ok(env, String(text))
        Error(Nil) -> err(env, "unknown command: " <> name)
      }
    _ -> {
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
          list.append(list.map(names(), fn(n) { "  " <> n }), [
            "",
            "Use `help <command>` for details. `^cmd` forces an external binary.",
            "Variables: `let x = ...` then `$x`. Pipeline input is `$in`.",
          ]),
        )
      ok(env, String(string.join(lines, "\n")))
    }
  }
}

fn help_text() -> dict.Dict(String, String) {
  dict.from_list([
    #("ls", "ls [path] — list directory entries as a table"),
    #("cd", "cd [path] — change directory (~ supported)"),
    #("pwd", "pwd — print working directory"),
    #("cat", "cat <path> — read file as string"),
    #("open", "open <path> — open file; parses .json into structured data"),
    #("save", "save <path> — save pipeline input to a file"),
    #(
      "where",
      "where <field> <op> <value> — filter rows (ops: == != > < >= <=)",
    ),
    #("select", "select <col>… — keep only named columns"),
    #("get", "get <field|index> — get a field or list index"),
    #("first", "first [n] — first row/item (default 1)"),
    #("last", "last [n] — last row/item"),
    #("take", "take <n> — take first n rows"),
    #("skip", "skip <n> — skip first n rows"),
    #("echo", "echo <values>… — emit values (list if multiple)"),
    #("to-json", "to-json — convert input to JSON string"),
    #("from-json", "from-json — parse JSON string input"),
    #("range", "range <end> | range <start> <end> — integer range list"),
    #("sys", "sys — host info record"),
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
  _flags: dict.Dict(String, Value),
) -> BuiltinResult {
  case args {
    [String(path)] -> {
      let path = resolve_path(env, path)
      case simplifile.read(path) {
        Ok(content) -> ok(env, String(content))
        Error(e) -> err(env, "cat: " <> simplifile.describe_error(e))
      }
    }
    _ -> err(env, "cat: expected path")
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

// --- json ---

fn cmd_to_json(
  env: Env,
  input: Value,
  _args: List(Value),
  _flags: dict.Dict(String, Value),
) -> BuiltinResult {
  ok(env, String(value_to_json_string(input)))
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
    "" -> err(env, "from-json: empty input")
    s ->
      case parse_json_value(s) {
        Ok(v) -> ok(env, v)
        Error(msg) -> err(env, "from-json: " <> msg)
      }
  }
}

fn value_to_json_string(v: Value) -> String {
  case v {
    Nothing -> "null"
    Bool(True) -> "true"
    Bool(False) -> "false"
    Int(n) -> int.to_string(n)
    Float(f) -> float.to_string(f)
    String(s) -> json_escape(s)
    List(items) ->
      "[" <> string.join(list.map(items, value_to_json_string), ",") <> "]"
    Record(fields) ->
      "{"
      <> string.join(
        list.map(fields, fn(pair) {
          let #(k, val) = pair
          json_escape(k) <> ":" <> value_to_json_string(val)
        }),
        ",",
      )
      <> "}"
    Table(cols, rows) -> {
      let records = list.map(rows, fn(row) { Record(list.zip(cols, row)) })
      value_to_json_string(List(records))
    }
    Fail(msg) -> json_escape("error: " <> msg)
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
    [String(name)] -> ok(env, env.get_var(env, name))
    [] -> {
      let pairs =
        env.vars
        |> dict.to_list
        |> list.map(fn(pair) {
          let #(k, v) = pair
          Record([
            #("name", String(k)),
            #("value", String(value.as_string(v))),
          ])
        })
      ok(env, value.table_from_records(pairs))
    }
    _ -> err(env, "env: unexpected args")
  }
}

fn cmd_which(
  env: Env,
  _input: Value,
  args: List(Value),
  _flags: dict.Dict(String, Value),
) -> BuiltinResult {
  case args {
    [String(name)] ->
      case dict.has_key(registry(), name) {
        True -> ok(env, String("builtin: " <> name))
        False ->
          case sys.which(name) {
            Ok(path) -> ok(env, String(path))
            Error(Nil) -> err(env, "which: " <> name <> " not found")
          }
      }
    _ -> err(env, "which: expected name")
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
