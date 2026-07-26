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
    // Assignments always capture external output into a value.
    Let(name, pipeline) ->
      case eval_pipeline(env, pipeline, Nothing, False) {
        Quit(code) -> Quit(code)
        Continue(env2, value) -> {
          case value {
            Fail(_) -> Continue(env2, value)
            _ -> Continue(env.set_var(env2, name, value), value)
          }
        }
      }
    EnvAssign(name, pipeline) ->
      case eval_pipeline(env, pipeline, Nothing, False) {
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
    // Bare expression: last stage may take a live TTY only if it needs one
    // (vim, sudo, …). Pager-using tools (systemctl, git, man) are captured
    // and shown via gleshell's builtin pager instead of system less.
    parser.Expr(pipeline) -> eval_pipeline(env, pipeline, Nothing, True)
  }
}

/// `allow_tty` — when True, the last pipeline stage *may* run on a live TTY
/// if `wants_tty` says it needs one (editors, TUIs, auth). Otherwise output
/// is captured (nested pagers → cat) for gleshell's pager.
fn eval_pipeline(
  env: Env,
  pipeline: Pipeline,
  input: Value,
  allow_tty: Bool,
) -> EvalResult {
  case pipeline {
    parser.Pipeline(commands) -> {
      let total = list.length(commands)
      list.index_fold(commands, Continue(env, input), fn(acc, cmd, index) {
        case acc {
          Quit(code) -> Quit(code)
          Continue(env2, value) ->
            case value {
              Fail(_) -> Continue(env2, value)
              _ -> {
                let is_last = index + 1 == total
                eval_command(env2, cmd, value, allow_tty && is_last)
              }
            }
        }
      })
    }
  }
}

fn eval_command(
  env: Env,
  cmd: Command,
  input: Value,
  interactive: Bool,
) -> EvalResult {
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
      case external {
        // Externals: keep argv order exactly as written (`jj log -n 1`, not
        // `-n 1 log`). Flag-first reordering is only for builtins.
        True ->
          case eval_argv(env, args) {
            Error(msg) -> Continue(env.set_exit(env, 1), Fail(msg))
            Ok(str_args) -> run_external(env, name, str_args, input, interactive)
          }
        False ->
          case eval_args(env, args) {
            Error(msg) -> Continue(env.set_exit(env, 1), Fail(msg))
            Ok(#(pos, flags)) -> {
              // Builtins produce a new value that was not streamed to the TTY.
              sys.clear_output_shown()
              case dict.get(builtins.registry(), name) {
                Ok(builtin) ->
                  case builtin(env, input, pos, flags) {
                    builtins.Exit(code) -> Quit(code)
                    builtins.BuiltinResult(env2, value) -> {
                      let env2 = case value {
                        Fail(_) -> env.set_exit(env2, 1)
                        _ -> env.set_exit(env2, 0)
                      }
                      Continue(env2, value)
                    }
                  }
                // Unknown name → external binary (preserve order).
                Error(Nil) ->
                  case eval_argv(env, args) {
                    Error(msg) -> Continue(env.set_exit(env, 1), Fail(msg))
                    Ok(str_args) ->
                      run_external(env, name, str_args, input, interactive)
                  }
              }
            }
          }
      }
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

/// Flatten command args to an argv for external programs, preserving order.
fn eval_argv(env: Env, args: List(Arg)) -> Result(List(String), String) {
  list.try_fold(args, [], fn(acc, arg) {
    case arg {
      ValueArg(expr) ->
        case eval_expr(env, expr) {
          Ok(v) -> Ok(list.append(acc, [value.as_string(v)]))
          Error(e) -> Error(e)
        }
      FlagArg(name, parser.None) -> {
        let flag = format_flag_name(name)
        Ok(list.append(acc, [flag]))
      }
      FlagArg(name, parser.Some(expr)) ->
        case eval_expr(env, expr) {
          Ok(v) -> {
            let flag = format_flag_name(name)
            Ok(list.append(acc, [flag, value.as_string(v)]))
          }
          Error(e) -> Error(e)
        }
    }
  })
}

fn format_flag_name(name: String) -> String {
  case string.starts_with(name, "-") {
    True -> name
    False ->
      case string.length(name) {
        1 -> "-" <> name
        _ -> "--" <> name
      }
  }
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

fn run_external(
  env: Env,
  name: String,
  str_args: List(String),
  input: Value,
  interactive: Bool,
) -> EvalResult {
  // Pipeline input becomes the external's stdin (Unix-style `cmd | less`).
  let stdin = stdin_bytes(input)
  // Prefer capture so tools that would spawn system `less` (systemctl, git,
  // man, …) dump full output with nested pagers disabled. The REPL then pages
  // through gleshell's builtin pager. Only true TUI/TTY programs inherit a
  // live terminal (vim, htop, sudo, ssh, …).
  let result = case interactive && wants_tty(name) {
    True -> sys.run_cmd_tty(name, str_args, stdin)
    False -> sys.run_cmd(name, str_args, stdin)
  }
  case result {
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

/// Bytes fed to an external's stdin from the previous pipeline stage.
fn stdin_bytes(input: Value) -> String {
  case input {
    Nothing -> ""
    String(s) -> s
    other -> value.as_string(other)
  }
}

/// True when the external must own a live TTY (full-screen UI, password
/// prompts, REPLs). Everything else is captured so systemctl/git/man use
/// gleshell's pager instead of spawning system `less`.
fn wants_tty(name: String) -> Bool {
  let base = command_basename(name)
  case base {
    // Editors
    "vi" | "vim" | "nvim" | "nano" | "emacs" | "emacsclient" | "helix" | "hx"
    | "kak" | "micro" | "ed" | "joe" -> True
    // Explicit system pagers (builtin `less` is separate; `^less` hits this)
    "less" | "more" | "most" -> True
    // Process / system monitors
    "top" | "htop" | "btop" | "glances" | "iotop" | "nethogs" | "nvtop"
    | "gtop" | "watch" -> True
    // File managers / TUIs
    "ranger" | "mc" | "nnn" | "lf" | "yazi" | "xplr" | "tig" | "gitui"
    | "lazygit" | "k9s" -> True
    // Interactive filters
    "fzf" | "peco" | "sk" -> True
    // Shells / REPLs
    "sh" | "bash" | "zsh" | "fish" | "nu" | "python" | "python3" | "ipython"
    | "node" | "irb" | "pry" | "lua" | "psql" | "mysql" | "redis-cli"
    | "sqlite3" | "iex" | "erl" -> True
    // Remote / auth (need a controlling TTY)
    "ssh" | "sftp" | "scp" | "mosh" | "telnet" | "sudo" | "doas" | "run0"
    | "pkexec" | "su" | "login" | "passwd" | "ssh-add" -> True
    // Multiplexers / debuggers / network TUI
    "tmux" | "screen" | "zellij" | "gdb" | "lldb" | "cgdb" | "nmtui"
    | "alsamixer" | "pulsemixer" | "bluetoothctl" -> True
    _ -> False
  }
}

fn command_basename(name: String) -> String {
  case string.split(name, "/") {
    [] -> name
    parts ->
      case list.last(parts) {
        Ok(b) -> b
        Error(Nil) -> name
      }
  }
}
