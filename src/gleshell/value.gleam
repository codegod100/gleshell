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
