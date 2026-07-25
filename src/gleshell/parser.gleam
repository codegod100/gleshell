//// Parse tokens into a Nushell-like AST (pipelines of commands).

import gleam/int
import gleam/list
import gleam/string
import gleshell/lexer.{
  type Token, Assign, BoolLit, Colon, Comma, Dollar, Eof, Eq, External, Flag,
  FloatLit, Ge, Gt, Ident, IntLit, LBrace, LBracket, Le, Lt, Ne, NothingLit,
  Pipe, RBrace, RBracket, StringLit,
}
import gleshell/value.{type Value}

pub type ParseError {
  ParseError(message: String)
}

pub type Statement {
  /// `let name = pipeline`
  Let(name: String, pipeline: Pipeline)
  /// `$env.NAME = pipeline` — set a process environment variable
  EnvAssign(name: String, pipeline: Pipeline)
  /// Bare pipeline expression
  Expr(pipeline: Pipeline)
}

pub type Pipeline {
  Pipeline(commands: List(Command))
}

pub type Command {
  Command(name: String, args: List(Arg), external: Bool)
}

pub type Arg {
  /// Literal or evaluated value expression
  ValueArg(Expr)
  /// `--flag` or `--flag value`
  FlagArg(name: String, value: Option(Expr))
}

pub type Option(a) {
  Some(a)
  None
}

pub type Expr {
  Lit(Value)
  Var(String)
  ListExpr(List(Expr))
  RecordExpr(List(#(String, Expr)))
}

pub fn parse(source: String) -> Result(Statement, String) {
  case lexer.tokenize(source) {
    Error(lexer.LexError(msg, pos)) ->
      Error("lex error at " <> int.to_string(pos) <> ": " <> msg)
    Ok(tokens) ->
      case parse_statement(tokens) {
        Ok(#(stmt, rest)) ->
          case skip_eof(rest) {
            [] -> Ok(stmt)
            leftover ->
              Error(
                "unexpected tokens after statement: "
                <> tokens_preview(leftover),
              )
          }
        Error(ParseError(msg)) -> Error(msg)
      }
  }
}

fn skip_eof(tokens: List(Token)) -> List(Token) {
  case tokens {
    [Eof] | [Eof, ..] | [] -> []
    other -> other
  }
}

fn tokens_preview(tokens: List(Token)) -> String {
  tokens
  |> list.take(5)
  |> list.map(token_name)
  |> string.join(", ")
}

fn token_name(t: Token) -> String {
  case t {
    Ident(s) -> "ident(" <> s <> ")"
    StringLit(_) -> "string"
    IntLit(_) -> "int"
    FloatLit(_) -> "float"
    BoolLit(_) -> "bool"
    Pipe -> "|"
    Flag(s) -> "--" <> s
    Eof -> "eof"
    Assign -> "="
    Eq -> "=="
    Ne -> "!="
    Gt -> ">"
    Lt -> "<"
    Ge -> ">="
    Le -> "<="
    External -> "^"
    _ -> "token"
  }
}

fn parse_statement(
  tokens: List(Token),
) -> Result(#(Statement, List(Token)), ParseError) {
  case tokens {
    [Ident("let"), Ident(name), Assign, ..rest] -> {
      use #(pipe, rest2) <- result_try(parse_pipeline(rest))
      Ok(#(Let(name, pipe), rest2))
    }
    // `$env.NAME = …` (Nushell-style process env assignment)
    [Dollar, Ident(name), Assign, ..rest] ->
      case string.starts_with(name, "env.") {
        True -> {
          let key = string.drop_start(name, 4)
          case key {
            "" ->
              Error(ParseError(
                "expected environment variable name after $env.",
              ))
            _ -> {
              use #(pipe, rest2) <- result_try(parse_assign_rhs(rest))
              Ok(#(EnvAssign(key, pipe), rest2))
            }
          }
        }
        False ->
          Error(ParseError(
            "only `$env.NAME = …` assignment is supported (use `let name = …` for shell vars)",
          ))
      }
    _ -> {
      use #(pipe, rest) <- result_try(parse_pipeline(tokens))
      Ok(#(Expr(pipe), rest))
    }
  }
}

fn result_try(
  r: Result(a, ParseError),
  f: fn(a) -> Result(b, ParseError),
) -> Result(b, ParseError) {
  case r {
    Ok(v) -> f(v)
    Error(e) -> Error(e)
  }
}

/// RHS of `$env.NAME = …`: a single expression becomes a value stage so bare
/// words are strings (`$env.FOO = hello`); otherwise a full pipeline
/// (`$env.FOO = range 3`, `$env.FOO = echo hi`).
fn parse_assign_rhs(
  tokens: List(Token),
) -> Result(#(Pipeline, List(Token)), ParseError) {
  case is_expr_start(tokens) {
    True ->
      case parse_expr(tokens) {
        Ok(#(expr, rest)) ->
          case rest {
            [] | [Eof] ->
              Ok(#(
                Pipeline([Command("__value__", [ValueArg(expr)], False)]),
                rest,
              ))
            _ -> parse_pipeline(tokens)
          }
        Error(_) -> parse_pipeline(tokens)
      }
    False -> parse_pipeline(tokens)
  }
}

fn parse_pipeline(
  tokens: List(Token),
) -> Result(#(Pipeline, List(Token)), ParseError) {
  use #(cmd, rest) <- result_try(parse_command(tokens))
  parse_pipeline_cont([cmd], rest)
}

fn parse_pipeline_cont(
  cmds: List(Command),
  tokens: List(Token),
) -> Result(#(Pipeline, List(Token)), ParseError) {
  case tokens {
    [Pipe, ..rest] -> {
      use #(cmd, rest2) <- result_try(parse_command(rest))
      parse_pipeline_cont(list.append(cmds, [cmd]), rest2)
    }
    _ -> Ok(#(Pipeline(cmds), tokens))
  }
}

fn parse_command(
  tokens: List(Token),
) -> Result(#(Command, List(Token)), ParseError) {
  case tokens {
    [External, Ident(name), ..rest] -> {
      use #(args, rest2) <- result_try(parse_args(rest, []))
      Ok(#(Command(name, args, True), rest2))
    }
    [Ident(name), ..rest] -> {
      use #(args, rest2) <- result_try(parse_args(rest, []))
      Ok(#(Command(name, args, False), rest2))
    }
    [StringLit(s), ..rest] -> {
      use #(args, rest2) <- result_try(parse_args(rest, []))
      Ok(#(Command(s, args, False), rest2))
    }
    // Bare value as pipeline stage: `$env`, `$x`, `[1 2]`, `{a: 1}`, …
    // Becomes internal `__value__` that yields the expression.
    [Dollar, ..]
    | [LBracket, ..]
    | [LBrace, ..]
    | [IntLit(_), ..]
    | [FloatLit(_), ..]
    | [BoolLit(_), ..]
    | [NothingLit, ..] -> {
      use #(expr, rest) <- result_try(parse_expr(tokens))
      Ok(#(Command("__value__", [ValueArg(expr)], False), rest))
    }
    [] | [Eof] -> Error(ParseError("expected command"))
    _ -> Error(ParseError("expected command name"))
  }
}

fn parse_args(
  tokens: List(Token),
  acc: List(Arg),
) -> Result(#(List(Arg), List(Token)), ParseError) {
  case tokens {
    [] | [Eof] | [Pipe, ..] -> Ok(#(list.reverse(acc), tokens))
    // Bare `--` (lexer Flag("")) → literal argv element, not a named flag.
    [Flag(""), ..rest] ->
      parse_args(rest, [ValueArg(Lit(value.String("--"))), ..acc])
    [Flag(name), ..rest] -> {
      case is_expr_start(rest) {
        True -> {
          use #(expr, rest2) <- result_try(parse_expr(rest))
          parse_args(rest2, [FlagArg(name, Some(expr)), ..acc])
        }
        False -> parse_args(rest, [FlagArg(name, None), ..acc])
      }
    }
    // Comparison operators as bare string args (for `where field == value`)
    [Eq, ..rest] -> parse_args(rest, [ValueArg(Lit(value.String("=="))), ..acc])
    [Ne, ..rest] -> parse_args(rest, [ValueArg(Lit(value.String("!="))), ..acc])
    [Gt, ..rest] -> parse_args(rest, [ValueArg(Lit(value.String(">"))), ..acc])
    [Lt, ..rest] -> parse_args(rest, [ValueArg(Lit(value.String("<"))), ..acc])
    [Ge, ..rest] -> parse_args(rest, [ValueArg(Lit(value.String(">="))), ..acc])
    [Le, ..rest] -> parse_args(rest, [ValueArg(Lit(value.String("<="))), ..acc])
    [Assign, ..rest] ->
      parse_args(rest, [ValueArg(Lit(value.String("=="))), ..acc])
    _ -> {
      case is_expr_start(tokens) {
        True -> {
          use #(expr, rest) <- result_try(parse_expr(tokens))
          parse_args(rest, [ValueArg(expr), ..acc])
        }
        False -> Ok(#(list.reverse(acc), tokens))
      }
    }
  }
}

fn is_expr_start(tokens: List(Token)) -> Bool {
  case tokens {
    [StringLit(_), ..]
    | [IntLit(_), ..]
    | [FloatLit(_), ..]
    | [BoolLit(_), ..]
    | [NothingLit, ..]
    | [LBracket, ..]
    | [LBrace, ..]
    | [Dollar, ..]
    | [Ident(_), ..] -> True
    _ -> False
  }
}

fn parse_expr(tokens: List(Token)) -> Result(#(Expr, List(Token)), ParseError) {
  case tokens {
    [StringLit(s), ..rest] -> Ok(#(Lit(value.String(s)), rest))
    [IntLit(n), ..rest] -> Ok(#(Lit(value.Int(n)), rest))
    [FloatLit(f), ..rest] -> Ok(#(Lit(value.Float(f)), rest))
    [BoolLit(b), ..rest] -> Ok(#(Lit(value.Bool(b)), rest))
    [NothingLit, ..rest] -> Ok(#(Lit(value.Nothing), rest))
    [Dollar, Ident(name), ..rest] -> Ok(#(Var(name), rest))
    [Dollar, ..] -> Error(ParseError("expected variable name after $"))
    [LBracket, ..rest] -> parse_list(rest)
    [LBrace, ..rest] -> parse_record(rest)
    [Ident(name), ..rest] -> Ok(#(Lit(value.String(name)), rest))
    _ -> Error(ParseError("expected expression"))
  }
}

fn parse_list(tokens: List(Token)) -> Result(#(Expr, List(Token)), ParseError) {
  parse_list_items(tokens, [])
}

fn parse_list_items(
  tokens: List(Token),
  acc: List(Expr),
) -> Result(#(Expr, List(Token)), ParseError) {
  case tokens {
    [RBracket, ..rest] -> Ok(#(ListExpr(list.reverse(acc)), rest))
    [Comma, ..rest] -> parse_list_items(rest, acc)
    _ -> {
      use #(expr, rest) <- result_try(parse_expr(tokens))
      parse_list_items(rest, [expr, ..acc])
    }
  }
}

fn parse_record(
  tokens: List(Token),
) -> Result(#(Expr, List(Token)), ParseError) {
  parse_record_fields(tokens, [])
}

fn parse_record_fields(
  tokens: List(Token),
  acc: List(#(String, Expr)),
) -> Result(#(Expr, List(Token)), ParseError) {
  case tokens {
    [RBrace, ..rest] -> Ok(#(RecordExpr(list.reverse(acc)), rest))
    [Comma, ..rest] -> parse_record_fields(rest, acc)
    [Ident(key), Colon, ..rest] | [StringLit(key), Colon, ..rest] -> {
      use #(expr, rest2) <- result_try(parse_expr(rest))
      parse_record_fields(rest2, [#(key, expr), ..acc])
    }
    _ -> Error(ParseError("expected record field `name: value` or `}`"))
  }
}
