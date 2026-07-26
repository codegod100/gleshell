//// Structured values inspired by Nushell — data, not just text streams.

import gleam/float
import gleam/int
import gleam/list
import gleam/order
import gleam/string

/// A shell value. Pipelines pass these between commands.
pub type Value {
  Nothing
  Bool(Bool)
  Int(Int)
  Float(Float)
  String(String)
  List(List(Value))
  /// Ordered key/value pairs (column order preserved).
  Record(List(#(String, Value)))
  /// Homogeneous table: column names + rows of values.
  Table(columns: List(String), rows: List(List(Value)))
  /// Runtime failure value (distinct from Result.Error).
  Fail(String)
}

pub fn type_name(value: Value) -> String {
  case value {
    Nothing -> "nothing"
    Bool(_) -> "bool"
    Int(_) -> "int"
    Float(_) -> "float"
    String(_) -> "string"
    List(_) -> "list"
    Record(_) -> "record"
    Table(_, _) -> "table"
    Fail(_) -> "error"
  }
}

pub fn is_truthy(value: Value) -> Bool {
  case value {
    Nothing -> False
    Bool(b) -> b
    Int(0) -> False
    Float(f) -> f != 0.0
    String("") -> False
    List([]) -> False
    Table(_, []) -> False
    Fail(_) -> False
    _ -> True
  }
}

pub fn as_string(value: Value) -> String {
  case value {
    Nothing -> ""
    Bool(True) -> "true"
    Bool(False) -> "false"
    Int(n) -> int.to_string(n)
    Float(f) -> float.to_string(f)
    String(s) -> s
    List(items) -> {
      let inner =
        items
        |> list.map(as_string)
        |> string.join(", ")
      "[" <> inner <> "]"
    }
    Record(fields) -> {
      let inner =
        fields
        |> list.map(fn(pair) {
          let #(k, v) = pair
          k <> ": " <> as_string(v)
        })
        |> string.join(", ")
      "{" <> inner <> "}"
    }
    Table(cols, rows) ->
      "table<"
      <> string.join(cols, ", ")
      <> "; "
      <> int.to_string(list.length(rows))
      <> " rows>"
    Fail(msg) -> "error: " <> msg
  }
}

/// Compact single-line representation for table cells.
pub fn cell_string(value: Value) -> String {
  case value {
    Nothing -> ""
    Bool(True) -> "true"
    Bool(False) -> "false"
    Int(n) -> int.to_string(n)
    Float(f) -> float.to_string(f)
    String(s) -> s
    List(items) ->
      "["
      <> {
        items
        |> list.map(cell_string)
        |> string.join(" ")
      }
      <> "]"
    Record(fields) ->
      "{"
      <> {
        fields
        |> list.map(fn(pair) {
          let #(k, v) = pair
          k <> ":" <> cell_string(v)
        })
        |> string.join(" ")
      }
      <> "}"
    Table(cols, rows) ->
      "table("
      <> int.to_string(list.length(cols))
      <> "x"
      <> int.to_string(list.length(rows))
      <> ")"
    Fail(msg) -> "error:" <> msg
  }
}

pub fn get_field(record: Value, name: String) -> Result(Value, String) {
  case record {
    Record(fields) ->
      case list.key_find(fields, name) {
        Ok(v) -> Ok(v)
        Error(Nil) -> Error("no field '" <> name <> "'")
      }
    Table(_, _) -> Error("use 'get' on a row record, not a table")
    other -> Error("expected record, got " <> type_name(other))
  }
}

/// Split a dotted cell path (`"foo.bar"` → `["foo", "bar"]`).
/// Empty segments (e.g. `"a..b"`) are rejected.
pub fn parse_cell_path(path: String) -> Result(List(String), String) {
  case path {
    "" -> Error("empty path")
    _ -> {
      let parts = string.split(path, ".")
      case list.any(parts, fn(p) { p == "" }) {
        True -> Error("invalid path '" <> path <> "' (empty segment)")
        False -> Ok(parts)
      }
    }
  }
}

/// Follow a Nushell-style cell path through records, lists, and tables.
/// Dots nest: `{a: {b: 1}} | get a.b` → `1`.
/// When a list/table is encountered mid-path, the rest of the path is applied
/// to each item (missing fields are skipped, matching plain `get` on lists).
pub fn get_path(value: Value, path: List(String)) -> Result(Value, String) {
  case path {
    [] -> Ok(value)
    [key, ..rest] ->
      case get_one(value, key) {
        Error(e) -> Error(e)
        Ok(next) ->
          case rest {
            [] -> Ok(next)
            _ ->
              case next {
                List(items) ->
                  Ok(
                    List(
                      list.filter_map(items, fn(item) {
                        case get_path(item, rest) {
                          Ok(v) -> Ok(v)
                          Error(_) -> Error(Nil)
                        }
                      }),
                    ),
                  )
                Table(_, _) ->
                  case table_to_records(next) {
                    Error(e) -> Error(e)
                    Ok(rows) ->
                      Ok(
                        List(
                          list.filter_map(rows, fn(row) {
                            case get_path(row, rest) {
                              Ok(v) -> Ok(v)
                              Error(_) -> Error(Nil)
                            }
                          }),
                        ),
                      )
                  }
                _ -> get_path(next, rest)
              }
          }
      }
  }
}

/// One path segment: field on a record, column on a table, or map over a list.
fn get_one(value: Value, key: String) -> Result(Value, String) {
  case value {
    Record(_) -> get_field(value, key)
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
          Ok(List(col_vals))
        }
        Error(Nil) -> Error("no column '" <> key <> "'")
      }
    List(items) ->
      Ok(
        List(
          list.filter_map(items, fn(item) {
            case get_field(item, key) {
              Ok(v) -> Ok(v)
              Error(_) -> Error(Nil)
            }
          }),
        ),
      )
    other -> Error("cannot get '" <> key <> "' from " <> type_name(other))
  }
}

fn list_index_of(items: List(String), target: String) -> Result(Int, Nil) {
  list_index_of_loop(items, target, 0)
}

fn list_index_of_loop(
  items: List(String),
  target: String,
  i: Int,
) -> Result(Int, Nil) {
  case items {
    [] -> Error(Nil)
    [x, ..rest] ->
      case x == target {
        True -> Ok(i)
        False -> list_index_of_loop(rest, target, i + 1)
      }
  }
}

fn list_at(items: List(Value), index: Int) -> Result(Value, Nil) {
  case index < 0 {
    True -> Error(Nil)
    False -> list_at_loop(items, index)
  }
}

fn list_at_loop(items: List(Value), index: Int) -> Result(Value, Nil) {
  case items {
    [] -> Error(Nil)
    [x, ..rest] ->
      case index {
        0 -> Ok(x)
        _ -> list_at_loop(rest, index - 1)
      }
  }
}

pub fn record_from_pairs(pairs: List(#(String, Value))) -> Value {
  Record(pairs)
}

/// Build a table from a list of records (union of keys, stable first-seen order).
pub fn table_from_records(records: List(Value)) -> Value {
  case records {
    [] -> Table([], [])
    _ -> {
      let columns =
        records
        |> list.fold([], fn(acc, rec) {
          case rec {
            Record(fields) ->
              list.fold(fields, acc, fn(cols, pair) {
                let #(k, _) = pair
                case list.contains(cols, k) {
                  True -> cols
                  False -> list.append(cols, [k])
                }
              })
            _ -> acc
          }
        })
      let rows =
        list.map(records, fn(rec) {
          case rec {
            Record(fields) ->
              list.map(columns, fn(col) {
                case list.key_find(fields, col) {
                  Ok(v) -> v
                  Error(Nil) -> Nothing
                }
              })
            other -> list.map(columns, fn(_) { other })
          }
        })
      Table(columns, rows)
    }
  }
}

/// Convert a table into a list of records.
pub fn table_to_records(table: Value) -> Result(List(Value), String) {
  case table {
    Table(cols, rows) ->
      Ok(list.map(rows, fn(row) { Record(list.zip(cols, row)) }))
    List(items) -> {
      case
        list.all(items, fn(v) {
          case v {
            Record(_) -> True
            _ -> False
          }
        })
      {
        True -> Ok(items)
        False -> Error("list is not a list of records")
      }
    }
    Record(_) as r -> Ok([r])
    other ->
      Error("expected table or list of records, got " <> type_name(other))
  }
}

pub fn length_of(value: Value) -> Int {
  case value {
    Nothing -> 0
    List(items) -> list.length(items)
    Table(_, rows) -> list.length(rows)
    String(s) -> string.length(s)
    Record(fields) -> list.length(fields)
    _ -> 1
  }
}

pub fn compare(a: Value, b: Value) -> Result(Cmp, String) {
  case a, b {
    Int(x), Int(y) -> Ok(order_to_cmp(int.compare(x, y)))
    Float(x), Float(y) -> Ok(order_to_cmp(float.compare(x, y)))
    Int(x), Float(y) -> Ok(order_to_cmp(float.compare(int.to_float(x), y)))
    Float(x), Int(y) -> Ok(order_to_cmp(float.compare(x, int.to_float(y))))
    String(x), String(y) -> Ok(order_to_cmp(string.compare(x, y)))
    Bool(x), Bool(y) ->
      Ok(case x, y {
        True, False -> Gt
        False, True -> Lt
        _, _ -> Eq
      })
    _, _ -> Error("cannot compare " <> type_name(a) <> " and " <> type_name(b))
  }
}

fn order_to_cmp(o: order.Order) -> Cmp {
  case o {
    order.Lt -> Lt
    order.Eq -> Eq
    order.Gt -> Gt
  }
}

pub type Cmp {
  Lt
  Eq
  Gt
}

pub fn equals(a: Value, b: Value) -> Bool {
  case compare(a, b) {
    Ok(Eq) -> True
    Ok(_) -> False
    Error(_) -> as_string(a) == as_string(b)
  }
}

/// Try to coerce pipeline input into rows (list of values).
pub fn as_rows(value: Value) -> List(Value) {
  case value {
    Nothing -> []
    List(items) -> items
    Table(cols, rows) -> list.map(rows, fn(row) { Record(list.zip(cols, row)) })
    other -> [other]
  }
}
