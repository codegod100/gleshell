import gleam/string
import gleeunit
import gleshell/color
import gleshell/display
import gleshell/env
import gleshell/eval
import gleshell/highlight
import gleshell/lexer
import gleshell/parser
import gleshell/sys
import gleshell/value.{Bool, Int, List, Nothing, Record, String, Table}

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

pub fn parse_ls_dotfile_test() {
  let assert Ok(parser.Expr(parser.Pipeline([
    parser.Command("ls", args, False),
  ]))) = parser.parse("ls .jj")
  let assert [parser.ValueArg(parser.Lit(String(".jj")))] = args
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

pub fn eval_from_json_test() {
  let env = env.new()
  let assert eval.Continue(_, Record(fields)) =
    eval.eval_source(env, "echo \"{\\\"x\\\": 1}\" | from json")
  let assert True = list_has_field(fields, "x", Int(1))
  Nil
}

pub fn eval_to_json_pretty_test() {
  let env = env.new()
  // Nushell-style multi-word `to json` — pretty by default
  let assert eval.Continue(_, String(pretty)) =
    eval.eval_source(env, "echo [1 2 3] | to json")
  let assert True = string.contains(pretty, "\n")
  let assert True = string.contains(pretty, "1")
  // `--raw` matches Nu: compact, no trailing newline
  let assert eval.Continue(_, String(raw)) =
    eval.eval_source(env, "echo [1 2 3] | to json --raw")
  let assert "[1,2,3]" = raw
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

pub fn color_visible_length_strips_ansi_test() {
  let painted = color.paint(True, "\u{001b}[32m", "hi")
  let assert 2 = color.visible_length(painted)
  let assert 2 = color.visible_length("hi")
  Nil
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

pub fn highlight_to_json_multiword_test() {
  let text = highlight.highlight(True, "range 3 | to json")
  let assert True = string_contains(text, "to json")
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
