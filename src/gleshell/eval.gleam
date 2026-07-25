//// Evaluate pipelines against the environment.

import gleam/dict
import gleam/int
import gleam/list
import gleam/string
import gleshell/builtins
import gleshell/env.{type Env}
import gleshell/parser.{
  type Arg, type Command, type Expr, type Pipeline, type Statement, EnvAssign,
  FlagArg, Let, ListExpr, Lit, RecordExpr, ValueArg, Var,
}
import gleshell/sys
import gleshell/value.{type Value, Fail, List, Nothing, Record, String}

pub type EvalResult {
  Continue(env: Env, value: Value)
  Quit(code: Int)
}

pub fn eval_source(env: Env, source: String) -> EvalResult {
  // Fresh statement — do not inherit a prior external command's TTY-shown flag.
  sys.clear_output_shown()
  let source = string.trim(source)
  case source {
    "" -> Continue(env, Nothing)
    _ ->
      case parser.parse(source) {
        Error(msg) -> Continue(env.set_exit(env, 1), Fail(msg))
        Ok(stmt) -> eval_statement(env, stmt)
      }
  }
}

fn eval_statement(env: Env, stmt: Statement) -> EvalResult {
  case stmt {
    Let(name, pipeline) ->
      case eval_pipeline(env, pipeline, Nothing) {
        Quit(code) -> Quit(code)
        Continue(env2, value) -> {
          case value {
            Fail(_) -> Continue(env2, value)
            _ -> Continue(env.set_var(env2, name, value), value)
          }
        }
      }
    EnvAssign(name, pipeline) ->
      case eval_pipeline(env, pipeline, Nothing) {
        Quit(code) -> Quit(code)
        Continue(env2, value) ->
          case value {
            Fail(_) -> Continue(env2, value)
            _ ->
              case env.set_os_env(env2, name, value) {
                Ok(env3) -> Continue(env.set_exit(env3, 0), value)
                Error(msg) ->
                  Continue(env.set_exit(env2, 1), Fail(msg))
              }
          }
      }
    parser.Expr(pipeline) -> eval_pipeline(env, pipeline, Nothing)
  }
}

fn eval_pipeline(env: Env, pipeline: Pipeline, input: Value) -> EvalResult {
  case pipeline {
    parser.Pipeline(commands) ->
      list.fold(commands, Continue(env, input), fn(acc, cmd) {
        case acc {
          Quit(code) -> Quit(code)
          Continue(env2, value) ->
            case value {
              Fail(_) -> Continue(env2, value)
              _ -> eval_command(env2, cmd, value)
            }
        }
      })
  }
}

fn eval_command(env: Env, cmd: Command, input: Value) -> EvalResult {
  case cmd {
    // Bare value stage produced by the parser for `$env`, `$x`, literals, …
    parser.Command("__value__", [ValueArg(expr)], False) -> {
      sys.clear_output_shown()
      let env = env.set_input(env, input)
      case eval_expr(env, expr) {
        Ok(v) -> Continue(env.set_exit(env, 0), v)
        Error(msg) -> Continue(env.set_exit(env, 1), Fail(msg))
      }
    }
    parser.Command(name, args, external) -> {
      let env = env.set_input(env, input)
      case eval_args(env, args) {
        Error(msg) -> Continue(env.set_exit(env, 1), Fail(msg))
        Ok(#(pos, flags)) -> {
          case external {
            True -> run_external(env, name, pos)
            False -> {
              // Builtins produce a new value that was not streamed to the TTY.
              sys.clear_output_shown()
              case resolve_builtin(name, pos) {
                Ok(#(builtin, pos2)) ->
                  case builtin(env, input, pos2, flags) {
                    builtins.Exit(code) -> Quit(code)
                    builtins.BuiltinResult(env2, value) -> {
                      let env2 = case value {
                        Fail(_) -> env.set_exit(env2, 1)
                        _ -> env.set_exit(env2, 0)
                      }
                      Continue(env2, value)
                    }
                  }
                // Unknown name → external binary (may set output_shown).
                Error(Nil) -> run_external(env, name, pos)
              }
            }
          }
        }
      }
    }
  }
}

/// Look up a builtin, including Nushell-style multi-word names (`to json`).
/// When `name` alone is missing, try consuming a following bare string arg.
fn resolve_builtin(
  name: String,
  pos: List(Value),
) -> Result(#(builtins.Builtin, List(Value)), Nil) {
  case dict.get(builtins.registry(), name) {
    Ok(builtin) -> Ok(#(builtin, pos))
    Error(Nil) ->
      case pos {
        [String(sub), ..rest] ->
          case dict.get(builtins.registry(), name <> " " <> sub) {
            Ok(builtin) -> Ok(#(builtin, rest))
            Error(Nil) -> Error(Nil)
          }
        _ -> Error(Nil)
      }
  }
}

fn eval_args(
  env: Env,
  args: List(Arg),
) -> Result(#(List(Value), dict.Dict(String, Value)), String) {
  list.try_fold(args, #([], dict.new()), fn(acc, arg) {
    let #(pos, flags) = acc
    case arg {
      ValueArg(expr) ->
        case eval_expr(env, expr) {
          Ok(v) -> Ok(#(list.append(pos, [v]), flags))
          Error(e) -> Error(e)
        }
      FlagArg(name, parser.Some(expr)) ->
        case eval_expr(env, expr) {
          Ok(v) -> Ok(#(pos, dict.insert(flags, name, v)))
          Error(e) -> Error(e)
        }
      FlagArg(name, parser.None) ->
        Ok(#(pos, dict.insert(flags, name, value.Bool(True))))
    }
  })
}

fn eval_expr(env: Env, expr: Expr) -> Result(Value, String) {
  case expr {
    Lit(v) -> Ok(v)
    Var(name) -> Ok(env.get_var(env, name))
    ListExpr(items) -> {
      case list.try_map(items, fn(e) { eval_expr(env, e) }) {
        Ok(vals) -> Ok(List(vals))
        Error(e) -> Error(e)
      }
    }
    RecordExpr(fields) -> {
      case
        list.try_map(fields, fn(pair) {
          let #(k, e) = pair
          case eval_expr(env, e) {
            Ok(v) -> Ok(#(k, v))
            Error(err) -> Error(err)
          }
        })
      {
        Ok(pairs) -> Ok(Record(pairs))
        Error(e) -> Error(e)
      }
    }
  }
}

fn run_external(env: Env, name: String, args: List(Value)) -> EvalResult {
  let str_args = list.map(args, value.as_string)
  case sys.run_cmd(name, str_args) {
    Error(msg) -> Continue(env.set_exit(env, 127), Fail(msg))
    Ok(#(status, output)) -> {
      let output = string.trim_end(output)
      let env = env.set_exit(env, status)
      case status {
        0 -> Continue(env, String(output))
        _ ->
          Continue(env, case output {
            "" -> Fail(name <> " exited with status " <> int.to_string(status))
            out -> String(out)
          })
      }
    }
  }
}
