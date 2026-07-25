import gleeunit
import gleshell/env
import gleshell/eval
import gleshell/lexer
import gleshell/parser
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
    eval.eval_source(env, "echo \"{\\\"x\\\": 1}\" | from-json")
  let assert True = list_has_field(fields, "x", Int(1))
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

pub fn value_nothing_falsey_test() {
  let assert False = value.is_truthy(Nothing)
  let assert True = value.is_truthy(Int(1))
  Nil
}
