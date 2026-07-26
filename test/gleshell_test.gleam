import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit
import gleshell/builtins
import gleshell/color
import gleshell/display
import gleshell/env
import gleshell/eval
import gleshell/highlight
import gleshell/lexer
import gleshell/pager
import gleshell/parser
import gleshell/syntax
import gleshell/sys
import gleshell/value.{Bool, Int, List, Nothing, Record, String, Table}
import simplifile

pub fn main() -> Nil {
  gleeunit.main()
}

// --- lexer ---

pub fn lexer_pipeline_test() {
  let assert Ok(tokens) = lexer.tokenize("ls | where type == file")
  let assert [lexer.Ident("ls"), lexer.Pipe, lexer.Ident("where"), ..] = tokens
  Nil
}

pub fn lexer_string_and_number_test() {
  let assert Ok(tokens) = lexer.tokenize("echo \"hi\" 42 3.14 true")
  let assert [
    lexer.Ident("echo"),
    lexer.StringLit("hi"),
    lexer.IntLit(42),
    lexer.FloatLit(3.14),
    lexer.BoolLit(True),
    lexer.Eof,
  ] = tokens
  Nil
}

pub fn lexer_path_idents_test() {
  // Dotfiles, relative/absolute paths, home — must be bare words for `ls .jj` etc.
  let assert Ok(tokens) = lexer.tokenize("ls .jj ./src ../foo /tmp ~ ~/code")
  let assert [
    lexer.Ident("ls"),
    lexer.Ident(".jj"),
    lexer.Ident("./src"),
    lexer.Ident("../foo"),
    lexer.Ident("/tmp"),
    lexer.Ident("~"),
    lexer.Ident("~/code"),
    lexer.Eof,
  ] = tokens
  Nil
}

pub fn lexer_bare_double_dash_test() {
  // POSIX end-of-options: `nix run . -- args` must not lex-error on bare `--`.
  let assert Ok(tokens) = lexer.tokenize("nix run . -- chadfowler.com yolo")
  let assert [
    lexer.Ident("nix"),
    lexer.Ident("run"),
    lexer.Ident("."),
    lexer.Flag(""),
    lexer.Ident("chadfowler.com"),
    lexer.Ident("yolo"),
    lexer.Eof,
  ] = tokens
  // Named long flags still work
  let assert Ok(tokens2) = lexer.tokenize("cmd --think --scale 3")
  let assert [
    lexer.Ident("cmd"),
    lexer.Flag("think"),
    lexer.Flag("scale"),
    lexer.IntLit(3),
    lexer.Eof,
  ] = tokens2
  Nil
}

pub fn parse_bare_double_dash_test() {
  let assert Ok(parser.Expr(parser.Pipeline([
    parser.Command("nix", args, False),
  ]))) = parser.parse("nix run . -- chadfowler.com yolo")
  let assert [
    parser.ValueArg(parser.Lit(String("run"))),
    parser.ValueArg(parser.Lit(String("."))),
    parser.ValueArg(parser.Lit(String("--"))),
    parser.ValueArg(parser.Lit(String("chadfowler.com"))),
    parser.ValueArg(parser.Lit(String("yolo"))),
  ] = args
  Nil
}

pub fn parse_ls_dotfile_test() {
  let assert Ok(parser.Expr(parser.Pipeline([
    parser.Command("ls", args, False),
  ]))) = parser.parse("ls .jj")
  let assert [parser.ValueArg(parser.Lit(String(".jj")))] = args
  Nil
}

pub fn parse_port_spec_arg_test() {
  // `lsof -i :4004` — colon is a record token but must be a bare argv word here.
  let assert Ok(parser.Expr(parser.Pipeline([
    parser.Command("lsof", args, False),
  ]))) = parser.parse("lsof -i :4004")
  let assert [
    parser.FlagArg("i", parser.None),
    parser.ValueArg(parser.Lit(String(":4004"))),
  ] = args
  // No space: `lsof -i:4004`
  let assert Ok(parser.Expr(parser.Pipeline([
    parser.Command("lsof", args2, False),
  ]))) = parser.parse("lsof -i:4004")
  let assert [
    parser.FlagArg("i", parser.None),
    parser.ValueArg(parser.Lit(String(":4004"))),
  ] = args2
  // Glued host:port and URL-shaped words
  let assert Ok(parser.Expr(parser.Pipeline([
    parser.Command("echo", args3, False),
  ]))) = parser.parse("echo host:4004 http://example.com")
  let assert [
    parser.ValueArg(parser.Lit(String("host:4004"))),
    parser.ValueArg(parser.Lit(String("http://example.com"))),
  ] = args3
  Nil
}

// --- parser ---

pub fn parse_pipeline_test() {
  let assert Ok(parser.Expr(parser.Pipeline(cmds))) =
    parser.parse("ls | first 3")
  let assert [
    parser.Command("ls", [], False),
    parser.Command("first", args, False),
  ] = cmds
  let assert [parser.ValueArg(parser.Lit(Int(3)))] = args
  Nil
}

pub fn parse_let_test() {
  let assert Ok(parser.Let(
    "x",
    parser.Pipeline([parser.Command("echo", args, False)]),
  )) = parser.parse("let x = echo 1")
  let assert [parser.ValueArg(parser.Lit(Int(1)))] = args
  Nil
}

pub fn parse_where_ops_test() {
  let assert Ok(parser.Expr(parser.Pipeline([
    parser.Command("where", args, False),
  ]))) = parser.parse("where type == file")
  let assert [
    parser.ValueArg(parser.Lit(String("type"))),
    parser.ValueArg(parser.Lit(String("=="))),
    parser.ValueArg(parser.Lit(String("file"))),
  ] = args
  Nil
}

pub fn parse_list_and_record_test() {
  let assert Ok(parser.Expr(parser.Pipeline([
    parser.Command("echo", args, False),
  ]))) = parser.parse("echo [1 2] {a: true}")
  let assert [
    parser.ValueArg(parser.ListExpr([parser.Lit(Int(1)), parser.Lit(Int(2))])),
    parser.ValueArg(parser.RecordExpr([#("a", parser.Lit(Bool(True)))])),
  ] = args
  Nil
}

// --- value helpers ---

pub fn table_from_records_test() {
  let rows = [
    Record([#("name", String("a")), #("n", Int(1))]),
    Record([#("name", String("b")), #("n", Int(2))]),
  ]
  let assert Table(
    ["name", "n"],
    [[String("a"), Int(1)], [String("b"), Int(2)]],
  ) = value.table_from_records(rows)
  Nil
}

// --- eval ---

pub fn eval_echo_and_range_test() {
  let env = env.new()
  let assert eval.Continue(_, List([Int(0), Int(1), Int(2)])) =
    eval.eval_source(env, "range 3")
  let assert eval.Continue(_, String("hello")) =
    eval.eval_source(env, "echo hello")
  Nil
}

pub fn eval_pipeline_reverse_first_test() {
  let env = env.new()
  let assert eval.Continue(_, Int(2)) =
    eval.eval_source(env, "range 3 | reverse | first")
  Nil
}

/// Pipeline input must become the external's stdin (`cat f | less`, `echo hi | wc`).
/// Use `let` so the last stage is capture mode even on a TTY (bare expressions
/// may inherit the terminal and return an empty string value).
pub fn eval_pipeline_stdin_to_external_test() {
  let env = env.new()
  // `echo` is a builtin; `wc` is external. Count bytes of "hello" (no trailing NL).
  let assert eval.Continue(_, String(out)) =
    eval.eval_source(env, "let n = echo hello | ^wc -c")
  let assert True = string.contains(out, "5")
  // Tight `cmd|cmd` form (no spaces around pipe)
  let assert eval.Continue(_, String(out2)) =
    eval.eval_source(env, "let m = echo ab|^wc -c")
  let assert True = string.contains(out2, "2")
  Nil
}

pub fn eval_let_and_var_test() {
  let env = env.new()
  let assert eval.Continue(env2, Int(7)) =
    eval.eval_source(env, "let n = echo 7")
  let assert eval.Continue(_, Int(7)) = eval.eval_source(env2, "echo $n")
  Nil
}

pub fn eval_env_var_get_test() {
  // `$env.HOME` and bare `$env.HOME` as pipeline source
  let env = env.new()
  let assert Ok(home) = sys.getenv("HOME")
  let assert eval.Continue(_, String(got)) =
    eval.eval_source(env, "echo $env.HOME")
  let assert True = got == home
  let assert eval.Continue(_, String(got2)) = eval.eval_source(env, "$env.HOME")
  let assert True = got2 == home
  Nil
}

pub fn eval_env_record_test() {
  let env = env.new()
  let assert eval.Continue(_, Record(fields)) = eval.eval_source(env, "$env")
  let assert True = list_has_string_field(fields, "HOME")
  let assert True = list_has_string_field(fields, "PATH")
  // `$env | get HOME`
  let assert eval.Continue(_, String(home)) =
    eval.eval_source(env, "$env | get HOME")
  let assert True = string.length(home) > 0
  Nil
}

pub fn eval_env_assign_test() {
  let env = env.new()
  let assert eval.Continue(env2, String("gleshell-test-val")) =
    eval.eval_source(env, "$env.GLESHELL_TEST_VAR = gleshell-test-val")
  let assert eval.Continue(_, String("gleshell-test-val")) =
    eval.eval_source(env2, "$env.GLESHELL_TEST_VAR")
  let assert Ok("gleshell-test-val") = sys.getenv("GLESHELL_TEST_VAR")
  Nil
}

pub fn parse_env_assign_test() {
  let assert Ok(parser.EnvAssign("FOO", parser.Pipeline([cmd]))) =
    parser.parse("$env.FOO = hello")
  let assert parser.Command(
    "__value__",
    [parser.ValueArg(parser.Lit(String("hello")))],
    False,
  ) = cmd
  Nil
}

fn list_has_string_field(
  fields: List(#(String, value.Value)),
  key: String,
) -> Bool {
  case fields {
    [] -> False
    [#(k, String(_)), ..] if k == key -> True
    [_, ..rest] -> list_has_string_field(rest, key)
  }
}

pub fn eval_where_select_test() {
  let env = env.new()
  // build table via records in a list, convert with table
  let assert eval.Continue(_, result) =
    eval.eval_source(
      env,
      "echo [{name: a, n: 1} {name: b, n: 2} {name: c, n: 3}] | table | where n > 1 | select name",
    )
  let assert Table(["name"], rows) = result
  let assert [[String("b")], [String("c")]] = rows
  Nil
}

pub fn about_command_test() {
  let env = env.new()
  let assert eval.Continue(_, String(text)) = eval.eval_source(env, "about")
  let assert True = string.contains(text, "gleshell")
  let assert True = string.contains(text, "nandi.uk")
  let assert True = string.contains(text, "NaNdi")
  let assert True = string.contains(text, "did:plc:ngokl2gnmpbvuvrfckja3g7p")
  let assert True = string.contains(text, "latha.org")
  let assert eval.Continue(_, String(which_out)) =
    eval.eval_source(env, "which about")
  let assert "builtin: about" = which_out
  Nil
}

pub fn help_covers_all_builtins_test() {
  // Every registered builtin must have a dedicated help_text entry.
  let assert [] = builtins.missing_help()

  let env = env.new()
  // which finds builtins; help must too (not "unknown command")
  let assert eval.Continue(_, String(which_out)) =
    eval.eval_source(env, "which table")
  let assert "builtin: table" = which_out
  let assert eval.Continue(_, String(help_out)) =
    eval.eval_source(env, "help table")
  let assert True = string.contains(help_out, "table")
  let assert True = string.contains(help_out, "coerce")

  // Parent commands with subcommands: `help to` / `help from` / `help http`.
  let assert eval.Continue(_, String(to_help)) =
    eval.eval_source(env, "help to")
  let assert True = string.contains(to_help, "json")
  let assert eval.Continue(_, String(from_help)) =
    eval.eval_source(env, "help from")
  let assert True = string.contains(from_help, "json")
  let assert eval.Continue(_, String(http_help)) =
    eval.eval_source(env, "help http")
  let assert True = string.contains(http_help, "get")
  let assert True = string.contains(http_help, "post")

  // Bare help lists every command with its one-line description.
  let assert eval.Continue(_, String(all)) = eval.eval_source(env, "help")
  list.each(builtins.names(), fn(name) {
    let assert True = string.contains(all, name)
  })

  let assert eval.Continue(env2, value.Fail(msg)) =
    eval.eval_source(env, "help not-a-real-cmd")
  let assert True = string.contains(msg, "unknown command")
  let assert 1 = env2.last_exit
  Nil
}

pub fn eval_from_json_test() {
  let env = env.new()
  let assert eval.Continue(_, Record(fields)) =
    eval.eval_source(env, "echo \"{\\\"x\\\": 1}\" | from json")
  let assert True = list_has_field(fields, "x", Int(1))
  Nil
}

pub fn eval_to_json_pretty_test() {
  let env = env.new()
  // `to` command + `json` subcommand — pretty by default
  let assert eval.Continue(_, String(pretty)) =
    eval.eval_source(env, "echo [1 2 3] | to json")
  let assert True = string.contains(pretty, "\n")
  let assert True = string.contains(pretty, "1")
  // `--raw` matches Nu: compact, no trailing newline
  let assert eval.Continue(_, String(raw)) =
    eval.eval_source(env, "echo [1 2 3] | to json --raw")
  let assert "[1,2,3]" = raw
  // Missing / unknown subcommand
  let assert eval.Continue(env2, value.Fail(msg)) =
    eval.eval_source(env, "echo 1 | to")
  let assert True = string.contains(msg, "subcommand")
  let assert 1 = env2.last_exit
  let assert eval.Continue(_, value.Fail(msg2)) =
    eval.eval_source(env, "echo 1 | to yaml")
  let assert True = string.contains(msg2, "unknown subcommand")
  Nil
}

pub fn eval_to_json_record_test() {
  let env = env.new()
  let assert eval.Continue(_, String(raw)) =
    eval.eval_source(env, "echo {a: 1, b: true} | to json -r")
  let assert True = string.contains(raw, "\"a\":1")
  let assert True = string.contains(raw, "\"b\":true")
  Nil
}

pub fn http_subcommand_errors_test() {
  let env = env.new()
  // Missing subcommand
  let assert eval.Continue(env2, value.Fail(msg)) =
    eval.eval_source(env, "http")
  let assert True = string.contains(msg, "subcommand")
  let assert 1 = env2.last_exit
  // Unknown subcommand
  let assert eval.Continue(_, value.Fail(msg2)) =
    eval.eval_source(env, "http foo")
  let assert True = string.contains(msg2, "unknown subcommand")
  // Missing URL
  let assert eval.Continue(_, value.Fail(msg3)) =
    eval.eval_source(env, "http get")
  let assert True = string.contains(msg3, "URL") || string.contains(msg3, "url")
  // Invalid URL
  let assert eval.Continue(_, value.Fail(msg4)) =
    eval.eval_source(env, "http get not-a-url")
  let assert True = string.contains(msg4, "invalid URL")
  // which / help
  let assert eval.Continue(_, String(which_out)) =
    eval.eval_source(env, "which http")
  let assert "builtin: http" = which_out
  Nil
}

pub fn http_get_live_test() {
  // Live request against postman-echo (JSON). Skip gracefully if offline.
  let env = env.new()
  case eval.eval_source(env, "http get --full https://postman-echo.com/get") {
    eval.Continue(_, Record(fields)) -> {
      let assert True = list_has_field(fields, "status", Int(200))
      let assert True = list_has_key(fields, "body")
      let assert True = list_has_key(fields, "headers")
      let assert True =
        list_has_field(fields, "url", String("https://postman-echo.com/get"))
      // Default path (no --full) parses JSON body into a record
      let assert eval.Continue(_, Record(body_fields)) =
        eval.eval_source(env, "http get https://postman-echo.com/get")
      let assert True = list_has_key(body_fields, "url")
      Nil
    }
    eval.Continue(_, value.Fail(msg)) -> {
      // Network unavailable — still assert the error is from http, not parse
      let assert True =
        string.contains(msg, "http:") || string.contains(msg, "failed")
      Nil
    }
    _ -> panic as "http get --full: unexpected eval result"
  }
}

pub fn http_post_json_live_test() {
  let env = env.new()
  case
    eval.eval_source(
      env,
      "http post --full https://postman-echo.com/post {name: gleshell}",
    )
  {
    eval.Continue(_, Record(fields)) -> {
      let assert True = list_has_field(fields, "status", Int(200))
      // JSON body should be parsed; postman-echo echoes under `json`
      case list_find_field(fields, "body") {
        Ok(Record(body)) -> {
          case list_find_field(body, "json") {
            Ok(Record(json_fields)) -> {
              let assert True =
                list_has_field(json_fields, "name", String("gleshell"))
              Nil
            }
            _ -> Nil
          }
        }
        _ -> Nil
      }
    }
    eval.Continue(_, value.Fail(_)) -> Nil
    _ -> panic as "http post --full: unexpected eval result"
  }
}

fn list_has_key(fields: List(#(String, value.Value)), key: String) -> Bool {
  case fields {
    [] -> False
    [#(k, _), ..rest] ->
      case k == key {
        True -> True
        False -> list_has_key(rest, key)
      }
  }
}

fn list_find_field(
  fields: List(#(String, value.Value)),
  key: String,
) -> Result(value.Value, Nil) {
  case fields {
    [] -> Error(Nil)
    [#(k, v), ..rest] ->
      case k == key {
        True -> Ok(v)
        False -> list_find_field(rest, key)
      }
  }
}

fn list_has_field(
  fields: List(#(String, value.Value)),
  key: String,
  expected: value.Value,
) -> Bool {
  case fields {
    [] -> False
    [#(k, v), ..rest] ->
      case k == key {
        True -> value.equals(v, expected)
        False -> list_has_field(rest, key, expected)
      }
  }
}

pub fn eval_length_test() {
  let env = env.new()
  let assert eval.Continue(_, Int(4)) =
    eval.eval_source(env, "range 4 | length")
  Nil
}

pub fn eval_which_builtin_test() {
  let env = env.new()
  let assert eval.Continue(_, String("builtin: ls")) =
    eval.eval_source(env, "which ls")
  Nil
}

pub fn eval_find_list_test() {
  let env = env.new()
  // Substring match (OR across terms)
  let assert eval.Continue(_, List(items)) =
    eval.eval_source(env, "echo [moe larry curly] | find l")
  let assert [String("larry"), String("curly")] = items
  // Multiple terms
  let assert eval.Continue(_, List(items2)) =
    eval.eval_source(env, "echo [a.toml b.md c.rs] | find toml md")
  let assert [String("a.toml"), String("b.md")] = items2
  // Exact number match
  let assert eval.Continue(_, List([Int(5)])) =
    eval.eval_source(env, "echo [1 5 3 4 35] | find 5")
  Nil
}

pub fn eval_find_ignore_case_invert_test() {
  let env = env.new()
  let assert eval.Continue(_, List(items)) =
    eval.eval_source(env, "echo [Hello world HELLO] | find hello -i")
  let assert [String("Hello"), String("HELLO")] = items
  // `-i term` may attach term to the flag; still works
  let assert eval.Continue(_, List(items2)) =
    eval.eval_source(env, "echo [Hello world HELLO] | find -i hello")
  let assert [String("Hello"), String("HELLO")] = items2
  let assert eval.Continue(_, List([String("cd")])) =
    eval.eval_source(env, "echo [ab cd] | find --invert a")
  Nil
}

pub fn eval_find_table_and_string_test() {
  let env = env.new()
  let assert eval.Continue(_, Table(["name", "type"], rows)) =
    eval.eval_source(
      env,
      "echo [{name: a, type: file} {name: b, type: dir}] | table | find file",
    )
  let assert [[String("a"), String("file")]] = rows
  // Single-line string: return the string if match, else nothing
  let assert eval.Continue(_, String("Cargo.toml")) =
    eval.eval_source(env, "echo Cargo.toml | find Cargo")
  let assert eval.Continue(_, Nothing) =
    eval.eval_source(env, "echo Cargo.toml | find zz")
  // Multi-line string → list of matching lines
  let assert eval.Continue(_, List(lines)) =
    eval.eval_source(env, "echo \"hi\nbye\nhi there\" | find hi")
  let assert [String("hi"), String("hi there")] = lines
  Nil
}

pub fn eval_find_regex_test() {
  let env = env.new()
  let assert eval.Continue(_, List(items)) =
    eval.eval_source(env, "echo [abc odb arc abf] | find --regex \"b.\"")
  let assert [String("abc"), String("abf")] = items
  // Regex + terms is rejected (Nu-compatible)
  let assert eval.Continue(env2, value.Fail(msg)) =
    eval.eval_source(env, "echo [abc] | find --regex \"b.\" x")
  let assert True = string.contains(msg, "regex")
  let assert 1 = env2.last_exit
  Nil
}

pub fn eval_which_all_test() {
  let env = env.new()
  // `-a` includes the builtin first, then any PATH copies of `ls`.
  let assert eval.Continue(_, result) = eval.eval_source(env, "which -a ls")
  case result {
    String("builtin: ls") -> Nil
    List([String("builtin: ls"), ..]) -> Nil
    other -> {
      let _ = other
      panic as "which -a ls should start with builtin: ls"
    }
  }
}

pub fn eval_which_external_test() {
  let env = env.new()
  // `sh` is not a gleshell builtin; should resolve via PATH.
  let assert eval.Continue(_, String(path)) = eval.eval_source(env, "which sh")
  let assert True = string.contains(path, "sh")
  Nil
}

pub fn value_nothing_falsey_test() {
  let assert False = value.is_truthy(Nothing)
  let assert True = value.is_truthy(Int(1))
  Nil
}

// --- display / color ---

pub fn display_plain_no_ansi_test() {
  let text = display.render_with(False, Bool(True))
  let assert "true" = text
  let assert False = string_contains(text, "\u{001b}")
  Nil
}

pub fn display_colored_has_ansi_test() {
  let text = display.render_with(True, Bool(True))
  let assert True = string_contains(text, "\u{001b}")
  let assert True = string_contains(text, "true")
  Nil
}

pub fn display_preserves_external_ansi_test() {
  // Pre-colored tool output (jj, git, …) must not be re-wrapped in string green.
  let app = "\u{001b}[1;31merror\u{001b}[0m: boom"
  let text = display.render_with(True, String(app))
  let assert True = text == app
  Nil
}

pub fn display_multiline_string_not_recolored_test() {
  let multi = "line1\nline2"
  let text = display.render_with(True, String(multi))
  let assert True = text == multi
  Nil
}

pub fn display_table_headers_colored_test() {
  let text =
    display.render_with(
      True,
      Table(["name", "type"], [[String("src"), String("dir")]]),
    )
  // bold green header + bright-blue dir name
  let assert True = string_contains(text, "\u{001b}[1;32m")
  let assert True = string_contains(text, "\u{001b}[94m")
  let assert True = string_contains(text, "src")
  Nil
}

pub fn format_filesize_units_test() {
  let assert "0 B" = display.format_filesize(0)
  let assert "512 B" = display.format_filesize(512)
  let assert "1023 B" = display.format_filesize(1023)
  let assert "1 KB" = display.format_filesize(1024)
  let assert "1.5 KB" = display.format_filesize(1536)
  let assert "1 MB" = display.format_filesize(1_048_576)
  let assert "1.5 MB" = display.format_filesize(1_048_576 + 524_288)
  let assert "1 GB" = display.format_filesize(1_073_741_824)
  Nil
}

pub fn display_size_column_humanized_test() {
  // Data stays as raw bytes (Int); only display shows KB/MB.
  let text =
    display.render_with(
      False,
      Table(["name", "size"], [[String("a"), Int(2048)]]),
    )
  let assert True = string_contains(text, "2 KB")
  let assert False = string_contains(text, "2048")
  Nil
}

pub fn color_visible_length_strips_ansi_test() {
  let painted = color.paint(True, "\u{001b}[32m", "hi")
  let assert 2 = color.visible_length(painted)
  let assert 2 = color.visible_length("hi")
  Nil
}

// --- less / pager ---

pub fn pager_wrap_respects_ansi_width_test() {
  // 10 visible chars of content; wrap at 4 → three physical lines.
  let painted = color.paint(True, "\u{001b}[32m", "abcdefghij")
  let lines = pager.wrap_line(painted, 4)
  let assert 3 = list.length(lines)
  // Each physical line still carries / continues color; visible width ≤ 4.
  list.each(lines, fn(line) {
    let assert True = color.visible_length(line) <= 4
  })
  // Joining without separators reconstructs the original SGR + text.
  let joined = string.join(lines, "")
  let assert True = string.contains(joined, "abcdefghij")
  let assert True = string.contains(joined, "\u{001b}[32m")
  Nil
}

pub fn pager_display_lines_splits_newlines_test() {
  let lines = pager.display_lines("a\nb\nc", 80)
  let assert ["a", "b", "c"] = lines
  Nil
}

pub fn strip_ansi_removes_csi_test() {
  let painted = color.paint(True, "\u{001b}[32m", "hello")
  let assert "hello" = color.strip_ansi(painted)
  let assert "plain" = color.strip_ansi("plain")
  let assert "ab" = color.strip_ansi("a\u{001b}[1;31mb\u{001b}[0m")
  Nil
}

pub fn pager_line_matches_strips_ansi_test() {
  let painted = color.paint(True, "\u{001b}[31m", "needle")
  let assert True = pager.line_matches(painted, "needle")
  let assert True = pager.line_matches(painted, "eed")
  // Case-insensitive: mixed / upper pattern still hits.
  let assert True = pager.line_matches(painted, "NEEDLE")
  let assert True = pager.line_matches(painted, "NeEd")
  let assert False = pager.line_matches(painted, "")
  // Pattern must not match inside CSI itself.
  let assert False = pager.line_matches(painted, "[31m")
  Nil
}

pub fn pager_find_after_and_before_test() {
  let lines = ["alpha", "bravo", "alpha", "charlie"]
  let assert Ok(#(0, False)) = pager.find_after(lines, "alpha", -1)
  let assert Ok(#(2, False)) = pager.find_after(lines, "alpha", 0)
  // Wrap from end back to first match.
  let assert Ok(#(0, True)) = pager.find_after(lines, "alpha", 2)
  let assert Error(Nil) = pager.find_after(lines, "zzz", -1)
  // Case-insensitive search.
  let assert Ok(#(0, False)) = pager.find_after(lines, "ALPHA", -1)
  let assert Ok(#(2, False)) = pager.find_after(lines, "AlPhA", 0)

  let assert Ok(#(2, False)) = pager.find_before(lines, "alpha", 3)
  let assert Ok(#(0, False)) = pager.find_before(lines, "alpha", 2)
  // Wrap from start back to last match.
  let assert Ok(#(2, True)) = pager.find_before(lines, "alpha", 0)
  let assert Ok(#(2, False)) = pager.find_before(lines, "ALPHA", 3)
  Nil
}

pub fn pager_find_empty_pattern_test() {
  let lines = ["a", "b"]
  let assert Error(Nil) = pager.find_after(lines, "", -1)
  let assert Error(Nil) = pager.find_before(lines, "", 2)
  Nil
}

pub fn pager_live_search_preview_test() {
  let lines = ["alpha", "bravo", "charlie", "alpha again"]
  // Empty query: stay put, no highlight.
  let assert #(2, None, None) = pager.live_search_preview(lines, "", 2)
  // Inclusive of start_offset (match on current top line).
  let assert #(0, Some("alpha"), None) =
    pager.live_search_preview(lines, "alpha", 0)
  // From mid-buffer: first match at or after start.
  let assert #(3, Some("alpha"), None) =
    pager.live_search_preview(lines, "alpha", 1)
  // Not found: keep start offset, still paint pattern, status suffix.
  let assert #(1, Some("zzz"), Some("not found")) =
    pager.live_search_preview(lines, "zzz", 1)
  // Progressive typing narrows: "ch" → charlie.
  let assert #(2, Some("ch"), None) = pager.live_search_preview(lines, "ch", 0)
  // Case-insensitive: upper pattern still finds lower content.
  let assert #(0, Some("ALPHA"), None) =
    pager.live_search_preview(lines, "ALPHA", 0)
  let assert #(3, Some("Alpha"), None) =
    pager.live_search_preview(lines, "Alpha", 1)
  Nil
}

pub fn pager_highlight_matches_test() {
  let out = pager.highlight_matches("hello world", "world")
  // Black on bright yellow accent.
  let assert True = string.contains(out, "\u{001b}[30;103m")
  let assert True = string.contains(out, "world")
  let assert True = string.contains(out, "\u{001b}[39;49m")
  let assert "hello world" = color.strip_ansi(out)

  // Case-insensitive highlight preserves original casing in the line.
  let ci = pager.highlight_matches("Hello World", "WORLD")
  let assert True = string.contains(ci, "\u{001b}[30;103m")
  let assert True = string.contains(ci, "World")
  let assert "Hello World" = color.strip_ansi(ci)

  // No match / empty pattern: unchanged.
  let assert "nope" = pager.highlight_matches("nope", "zzz")
  let assert "x" = pager.highlight_matches("x", "")

  // Multiple non-overlapping hits.
  let multi = pager.highlight_matches("aa x aa", "aa")
  let parts = string.split(multi, "\u{001b}[30;103m")
  let assert 3 = list.length(parts)

  // ANSI around the match is preserved; highlight still finds visible text.
  let painted = color.paint(True, "\u{001b}[32m", "needle here")
  let hi = pager.highlight_matches(painted, "needle")
  let assert True = string.contains(hi, "\u{001b}[32m")
  let assert True = string.contains(hi, "\u{001b}[30;103m")
  let assert "needle here" = color.strip_ansi(hi)
  let assert True = string.contains(hi, "\u{001b}[39;49m")
  Nil
}

pub fn pager_highlight_match_spanning_sgr_test() {
  // Match crosses a mid-string color change: black-on-yellow re-opens after SGR.
  let line = "ab\u{001b}[31mcd\u{001b}[0mef"
  let hi = pager.highlight_matches(line, "bcde")
  let assert True = string.contains(hi, "\u{001b}[30;103m")
  let assert "abcdef" = color.strip_ansi(hi)
  // After the red open, accent should be re-applied inside the match.
  let assert True = string.contains(hi, "\u{001b}[31m\u{001b}[30;103m")
  Nil
}

pub fn less_short_output_passthrough_test() {
  // Non-TTY test runner: needs_paging is false → less returns the text.
  let env = env.new()
  let assert eval.Continue(_, String(out)) =
    eval.eval_source(env, "echo hello | less")
  let assert True = string.contains(out, "hello")
  let assert eval.Continue(_, String(which_out)) =
    eval.eval_source(env, "which less")
  let assert "builtin: less" = which_out
  Nil
}

pub fn less_preserves_ansi_in_string_test() {
  let env = env.new()
  // Pre-colored multi-line text must survive less (no re-paint / strip).
  let colored = "\u{001b}[31mred\u{001b}[0m\n\u{001b}[32mgreen\u{001b}[0m"
  let assert eval.Continue(_, String(out)) =
    eval.eval_source(env, "echo \"" <> escape_for_source(colored) <> "\" | less")
  let assert True = string.contains(out, "\u{001b}[31m")
  let assert True = string.contains(out, "red")
  let assert True = string.contains(out, "\u{001b}[32m")
  let assert True = string.contains(out, "green")
  Nil
}

pub fn less_no_input_errors_test() {
  let env = env.new()
  let assert eval.Continue(env2, value.Fail(msg)) = eval.eval_source(env, "less")
  let assert True = string.contains(msg, "no input")
  let assert 1 = env2.last_exit
  Nil
}

pub fn less_help_test() {
  let env = env.new()
  let assert eval.Continue(_, String(help_out)) =
    eval.eval_source(env, "help less")
  let assert True = string.contains(help_out, "ANSI")
  let assert True = string.contains(help_out, "q")
  let assert True = string.contains(help_out, "/pattern")
  let assert True = string.contains(help_out, "n / N")
  Nil
}

pub fn git_log_pipeline_emits_ansi_and_decorate_test() {
  // Capture uses a throwaway PTY when color is wanted, so git colorizes and
  // keeps ref decorations without GIT_CONFIG_* hacks. FORCE_COLOR makes
  // want_child_color true in non-TTY test runners.
  let prev = sys.getenv("FORCE_COLOR")
  let assert Ok(_) = sys.setenv("FORCE_COLOR", "1")
  let env = env.new()
  // Full log (not --oneline): decorations appear on the commit line.
  let result = eval.eval_source(env, "git log -1 | identity")
  case prev {
    Ok(v) -> {
      let assert Ok(_) = sys.setenv("FORCE_COLOR", v)
      Nil
    }
    Error(Nil) -> {
      let assert Ok(_) = sys.setenv("FORCE_COLOR", "")
      Nil
    }
  }
  let assert eval.Continue(_, String(out)) = result
  // Real git colors, not gleshell string-green on plain text.
  let assert True = string.contains(out, "\u{001b}[")
  // TTY-style decorate: ref names like HEAD / main.
  let assert True = string.contains(out, "HEAD") || string.contains(out, "main")
  Nil
}

pub fn jj_log_pipeline_emits_ansi_test() {
  // jj ignores FORCE_COLOR; PTY capture is what keeps colors for `jj log | less`.
  let prev = sys.getenv("FORCE_COLOR")
  let assert Ok(_) = sys.setenv("FORCE_COLOR", "1")
  let env = env.new()
  let result = eval.eval_source(env, "jj log -n 1 | identity")
  case prev {
    Ok(v) -> {
      let assert Ok(_) = sys.setenv("FORCE_COLOR", v)
      Nil
    }
    Error(Nil) -> {
      let assert Ok(_) = sys.setenv("FORCE_COLOR", "")
      Nil
    }
  }
  let assert eval.Continue(_, String(out)) = result
  let assert True = string.contains(out, "\u{001b}[")
  Nil
}

/// Embed a string in double-quoted source: escape `\` and `"`.
fn escape_for_source(s: String) -> String {
  s
  |> string.replace("\\", "\\\\")
  |> string.replace("\"", "\\\"")
}

// --- input syntax highlighting ---

pub fn highlight_plain_when_off_test() {
  let src = "ls | where type == file"
  let assert True = highlight.highlight(False, src) == src
  Nil
}

pub fn highlight_pipeline_has_shapes_test() {
  let text = highlight.highlight(True, "ls | first 3")
  // bold cyan internalcall, bold purple pipe, bold purple int
  let assert True = string_contains(text, "\u{001b}[1;36m")
  let assert True = string_contains(text, "\u{001b}[1;35m")
  let assert True = string_contains(text, "ls")
  let assert True = string_contains(text, "first")
  let assert True = string_contains(text, "3")
  // visible text unchanged
  let assert 12 = color.visible_length(text)
  Nil
}

pub fn highlight_string_and_flag_test() {
  let text = highlight.highlight(True, "echo \"hi\" --raw")
  let assert True = string_contains(text, "\u{001b}[32m")
  let assert True = string_contains(text, "\u{001b}[1;34m")
  let assert True = string_contains(text, "hi")
  let assert True = string_contains(text, "--raw")
  Nil
}

pub fn highlight_variable_and_let_test() {
  let text = highlight.highlight(True, "let x = $in")
  let assert True = string_contains(text, "\u{001b}[1;36m")
  let assert True = string_contains(text, "\u{001b}[35m")
  let assert True = string_contains(text, "let")
  let assert True = string_contains(text, "$in")
  Nil
}

pub fn highlight_incomplete_string_test() {
  // Unterminated string while typing should not crash
  let text = highlight.highlight(True, "echo \"hel")
  let assert True = string_contains(text, "hel")
  let assert True = string_contains(text, "\u{001b}[32m")
  Nil
}

pub fn highlight_to_command_test() {
  // `to` is a builtin; `json` is a subcommand arg
  let text = highlight.highlight(True, "range 3 | to json")
  let assert True = string_contains(text, "to")
  let assert True = string_contains(text, "json")
  let assert True = string_contains(text, "\u{001b}[1;36m")
  Nil
}

pub fn highlight_path_arg_not_garbage_test() {
  // Dotfile paths must not use shape_garbage (white-on-red)
  let text = highlight.highlight(True, "ls .jj ./src /tmp ~/code")
  let assert True = string_contains(text, ".jj")
  let assert False = string_contains(text, "\u{001b}[1;37;41m")
  // args use shape_externalarg (bold green)
  let assert True = string_contains(text, "\u{001b}[1;32m")
  Nil
}

fn string_contains(haystack: String, needle: String) -> Bool {
  case string.split(haystack, needle) {
    [_] -> False
    _ -> True
  }
}

// --- file syntax (cat highlighters) ---

pub fn syntax_language_from_path_test() {
  let assert syntax.Json = syntax.language_from_path("data/foo.json")
  let assert syntax.Gleam = syntax.language_from_path("src/main.gleam")
  let assert syntax.Toml = syntax.language_from_path("gleam.toml")
  let assert syntax.Markdown = syntax.language_from_path("README.md")
  let assert syntax.Plain = syntax.language_from_path("notes.txt")
  let assert syntax.Plain = syntax.language_from_path("Makefile")
  Nil
}

pub fn syntax_detect_sniff_json_test() {
  let assert syntax.Json = syntax.detect("data", "{\"a\": 1}")
  let assert syntax.Markdown = syntax.detect("notes", "# Title\n\nbody")
  let assert syntax.Plain = syntax.detect("x", "just words")
  // Extension wins over sniff
  let assert syntax.Toml = syntax.detect("x.toml", "{\"a\": 1}")
  Nil
}

pub fn syntax_is_binary_test() {
  let assert False = syntax.is_binary("hello\nworld\t!")
  let assert True = syntax.is_binary("a\u{0000}b")
  Nil
}

pub fn syntax_paint_json_test() {
  let src = "{\"n\": 1, \"msg\": \"hi\", \"ok\": true}"
  let assert True = syntax.paint(False, syntax.Json, src) == src
  let painted = syntax.paint(True, syntax.Json, src)
  // Truecolor roles: keys (sky), string values (green), numbers, bools
  let assert True = string_contains(painted, "38;2")
  let assert True = string_contains(painted, "true")
  let assert True = string_contains(painted, "137;220;235")
  let assert True = string_contains(painted, "166;227;161")
  let assert True = string_contains(painted, "250;179;135")
  let assert True = color.strip_ansi(painted) == src
  Nil
}

pub fn syntax_paint_gleam_test() {
  let src = "pub fn main() {\n  // hi\n  42\n}"
  let painted = syntax.paint(True, syntax.Gleam, src)
  // keyword mauve, fn name blue, comment italic, number peach
  let assert True = string_contains(painted, "203;166;247")
  let assert True = string_contains(painted, "137;180;250")
  let assert True = string_contains(painted, "108;112;134")
  let assert True = string_contains(painted, "250;179;135")
  let assert True = string_contains(painted, "pub")
  let assert True = string_contains(painted, "main")
  let assert True = color.strip_ansi(painted) == src
  Nil
}

pub fn syntax_paint_toml_test() {
  let src = "name = \"gleshell\"\n# comment\nenabled = true"
  let painted = syntax.paint(True, syntax.Toml, src)
  let assert True = string_contains(painted, "38;2")
  let assert True = string_contains(painted, "166;227;161")
  let assert True = string_contains(painted, "108;112;134")
  let assert True = color.strip_ansi(painted) == src
  Nil
}

pub fn syntax_paint_markdown_test() {
  let src = "# Title\n\nUse `code` and **bold**.\n"
  let painted = syntax.paint(True, syntax.Markdown, src)
  let assert True = string_contains(painted, "Title")
  let assert True = string_contains(painted, "code")
  // H1 lavender + bold peach for **bold**
  let assert True = string_contains(painted, "180;190;254")
  let assert True = string_contains(painted, "250;179;135")
  let assert True = color.visible_length(painted)
    >= color.visible_length(src) - 1
  Nil
}

pub fn syntax_frame_gutter_test() {
  let body = "alpha\nbeta"
  let framed = syntax.frame("src/demo.gleam", syntax.Gleam, body)
  let stripped = color.strip_ansi(framed)
  // Header carries basename + language badge
  let assert True = string_contains(stripped, "demo.gleam")
  let assert True = string_contains(stripped, "gleam")
  // Line numbers + pipe gutter
  let assert True = string_contains(stripped, "1")
  let assert True = string_contains(stripped, "2")
  let assert True = string_contains(stripped, "│")
  let assert True = string_contains(stripped, "alpha")
  let assert True = string_contains(stripped, "beta")
  Nil
}

pub fn cat_raw_and_language_test() {
  let env = env.new()
  // Write a temp json file under the project (simplifile needs a real path).
  let path = "build/cat_syntax_test.json"
  let body = "{\"x\": 1}"
  let assert Ok(Nil) = simplifile.write(to: path, contents: body)

  // --raw must return plain content even when colors would be on.
  let assert eval.Continue(_, String(raw_out)) =
    eval.eval_source(env, "cat " <> path <> " --raw")
  let assert True = raw_out == body

  // --language plain: no syntax colors (may still frame with line numbers on TTY).
  let assert eval.Continue(_, String(plain_out)) =
    eval.eval_source(env, "cat " <> path <> " --language plain")
  let plain_stripped = color.strip_ansi(plain_out)
  let assert True =
    plain_out == body
    || plain_stripped == body
    || string_contains(plain_stripped, body)

  // Forced gleam: visible body still present (gutter/header OK).
  let assert eval.Continue(_, String(gleam_out)) =
    eval.eval_source(env, "cat " <> path <> " --language gleam")
  let gleam_stripped = color.strip_ansi(gleam_out)
  let assert True =
    gleam_stripped == body || string_contains(gleam_stripped, body)

  // Unknown language errors.
  let assert eval.Continue(_, value.Fail(msg)) =
    eval.eval_source(env, "cat " <> path <> " --language cobol")
  let assert True = string.contains(msg, "unknown language")

  let _ = simplifile.delete(path)
  Nil
}

// --- tab completion ---

pub fn complete_command_builtin_test() {
  // Start of line: complete builtins
  let #(matches, kind) = sys.complete_word("", "ech")
  let assert True = kind == "command"
  let assert True = list_contains(matches, "echo")
  // After pipeline separator
  let #(matches2, kind2) = sys.complete_word("ls | ", "wher")
  let assert True = kind2 == "command"
  let assert True = list_contains(matches2, "where")
  // `to` / `from` are single-word commands (subcommand is a normal arg)
  let #(matches3, kind3) = sys.complete_word("", "to")
  let assert True = kind3 == "command"
  let assert True = list_contains(matches3, "to")
  let #(matches_from, kind_from) = sys.complete_word("", "fro")
  let assert True = kind_from == "command"
  let assert True = list_contains(matches_from, "from")
  // Keyword
  let #(matches4, kind4) = sys.complete_word("", "le")
  let assert True = kind4 == "command"
  let assert True = list_contains(matches4, "let")
  Nil
}

pub fn complete_command_after_assign_test() {
  let #(matches, kind) = sys.complete_word("let x = ", "ran")
  let assert True = kind == "command"
  let assert True = list_contains(matches, "range")
  Nil
}

pub fn complete_path_for_args_test() {
  // After a command name, Tab completes files not commands
  let #(_matches, kind) = sys.complete_word("echo ", "ech")
  let assert True = kind == "path"
  Nil
}

pub fn complete_path_like_command_test() {
  // Path-shaped command words stay on filename completion
  let #(_matches, kind) = sys.complete_word("", "./ec")
  let assert True = kind == "path"
  let #(_matches2, kind2) = sys.complete_word("", "/us")
  let assert True = kind2 == "path"
  Nil
}

pub fn complete_path_executable_test() {
  // PATH + builtins for a non-empty prefix
  let #(matches, kind) = sys.complete_word("", "s")
  let assert True = kind == "command"
  // At least builtins starting with s (select, skip, sort-by, …)
  let assert True = list_contains(matches, "select")
  Nil
}

// --- history ghost-text hints (Nu/fish style) ---

pub fn history_hint_newest_prefix_test() {
  // Newest-first: first entry that has the buffer as a proper prefix wins.
  let hist = ["ls | where type == file", "ls | first 3", "echo hi"]
  let assert " | where type == file" = sys.history_hint(hist, "ls")
  let assert " | first 3" = sys.history_hint(["ls | first 3", "ls | where x"], "ls")
  let assert " type == file" = sys.history_hint(hist, "ls | where")
  let assert " hi" = sys.history_hint(hist, "echo")
  Nil
}

pub fn history_hint_no_match_test() {
  let hist = ["ls", "echo hi"]
  let assert "" = sys.history_hint(hist, "cd")
  // Exact match only — no suffix
  let assert "" = sys.history_hint(hist, "ls")
  // Empty buffer never suggests
  let assert "" = sys.history_hint(hist, "")
  Nil
}

fn list_contains(items: List(String), needle: String) -> Bool {
  case items {
    [] -> False
    [x, ..] if x == needle -> True
    [_, ..rest] -> list_contains(rest, needle)
  }
}
