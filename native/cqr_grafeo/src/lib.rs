// CQR Grafeo NIF — Embeds Grafeo graph database into the BEAM
//
// NIF surface:
//   new/1          — create/open a Grafeo database instance
//   execute/2      — execute a query (GQL, Cypher, etc.)
//   checkpoint/1   — flush WAL + snapshot to disk without closing
//   close/1        — close the database instance
//   health_check/1 — report operational status

use grafeo::GrafeoDB;
use grafeo_common::types::Value;
use rustler::{Atom, Encoder, Env, NifResult, ResourceArc, Term};
use std::collections::BTreeMap;
use std::sync::Mutex;

mod atoms {
    rustler::atoms! {
        ok,
        error,
        memory,
        nil,
    }
}

/// Wrapper to allow close semantics — GrafeoDB is Send+Sync but we
/// need Option to support explicit close.
struct GrafeoResource {
    db: Mutex<Option<GrafeoDB>>,
}

#[rustler::resource_impl]
impl rustler::Resource for GrafeoResource {}

#[rustler::nif]
fn new(path: Term) -> NifResult<(Atom, ResourceArc<GrafeoResource>)> {
    let db = if path.is_atom() {
        // :memory -> in-memory database
        GrafeoDB::new_in_memory()
    } else {
        let path_str: String = path.decode()?;
        // Sync durability fsyncs after every commit. The default Batch mode
        // loses up-to-100ms of writes on SIGKILL, which for a single-user
        // MCP server doing tens of writes per session is a bad trade.
        let config = grafeo::Config::persistent(&path_str)
            .with_storage_format(grafeo_engine::config::StorageFormat::SingleFile)
            .with_wal_durability(grafeo::DurabilityMode::Sync);
        match GrafeoDB::with_config(config) {
            Ok(db) => db,
            Err(e) => {
                return Err(rustler::Error::Term(Box::new(format!(
                    "Failed to open Grafeo at {}: {}",
                    path_str, e
                ))));
            }
        }
    };

    let resource = ResourceArc::new(GrafeoResource {
        db: Mutex::new(Some(db)),
    });
    Ok((atoms::ok(), resource))
}

#[rustler::nif(schedule = "DirtyIo")]
fn execute(env: Env, resource: ResourceArc<GrafeoResource>, query: String) -> NifResult<Term> {
    let guard = resource
        .db
        .lock()
        .map_err(|_| rustler::Error::Term(Box::new("Mutex poisoned")))?;

    let db = guard
        .as_ref()
        .ok_or_else(|| rustler::Error::Term(Box::new("Database closed")))?;

    match db.execute(&query) {
        Ok(result) => {
            let rows = query_result_to_term(env, &result);
            Ok((atoms::ok(), rows).encode(env))
        }
        Err(e) => Ok((atoms::error(), format!("{}", e)).encode(env)),
    }
}

/// Flush WAL and snapshot to disk without closing the database.
///
/// For SingleFile storage this writes the current state to the `.grafeo`
/// file so a SIGKILL won't discard in-memory writes since the last
/// checkpoint. No-op for in-memory databases.
#[rustler::nif(schedule = "DirtyIo")]
fn checkpoint(resource: ResourceArc<GrafeoResource>) -> NifResult<Atom> {
    let guard = resource
        .db
        .lock()
        .map_err(|_| rustler::Error::Term(Box::new("Mutex poisoned")))?;

    let db = guard
        .as_ref()
        .ok_or_else(|| rustler::Error::Term(Box::new("Database closed")))?;

    db.wal_checkpoint()
        .map_err(|e| rustler::Error::Term(Box::new(format!("Checkpoint failed: {}", e))))?;

    Ok(atoms::ok())
}

#[rustler::nif]
fn close(resource: ResourceArc<GrafeoResource>) -> NifResult<Atom> {
    let mut guard = resource
        .db
        .lock()
        .map_err(|_| rustler::Error::Term(Box::new("Mutex poisoned")))?;

    let _ = guard.take();
    Ok(atoms::ok())
}

#[rustler::nif]
fn health_check(resource: ResourceArc<GrafeoResource>) -> NifResult<(Atom, String)> {
    let guard = resource
        .db
        .lock()
        .map_err(|_| rustler::Error::Term(Box::new("Mutex poisoned")))?;

    match guard.as_ref() {
        Some(_) => Ok((atoms::ok(), "grafeo 0.5.34".to_string())),
        None => Err(rustler::Error::Term(Box::new("Database closed"))),
    }
}

/// Convert a Grafeo QueryResult into an Elixir list of maps.
///
/// Each row becomes a map of column_name => value, matching the
/// smoke test expectation: [%{"t.name" => "hello"}]
fn query_result_to_term<'a>(
    env: Env<'a>,
    result: &grafeo::QueryResult,
) -> Term<'a> {
    let rows: Vec<Term<'a>> = result
        .rows
        .iter()
        .map(|row| {
            let pairs: Vec<(Term<'a>, Term<'a>)> = row
                .iter()
                .enumerate()
                .map(|(i, val)| {
                    let key = if i < result.columns.len() {
                        result.columns[i].as_str().encode(env)
                    } else {
                        format!("col_{}", i).encode(env)
                    };
                    let value = value_to_term(env, val);
                    (key, value)
                })
                .collect();
            Term::map_from_pairs(env, &pairs).unwrap_or_else(|_| atoms::nil().encode(env))
        })
        .collect();

    rows.encode(env)
}

/// Convert a single Grafeo Value to an Elixir term.
fn value_to_term<'a>(env: Env<'a>, value: &Value) -> Term<'a> {
    match value {
        Value::Null => atoms::nil().encode(env),
        Value::Bool(b) => b.encode(env),
        Value::Int64(i) => i.encode(env),
        Value::Float64(f) => f.encode(env),
        Value::String(s) => s.as_str().encode(env),
        Value::Bytes(b) => b.as_ref().encode(env),
        Value::List(items) => {
            let terms: Vec<Term<'a>> = items.iter().map(|v| value_to_term(env, v)).collect();
            terms.encode(env)
        }
        Value::Map(map) => map_to_term(env, map),
        Value::Vector(v) => {
            let floats: Vec<f32> = v.to_vec();
            floats.encode(env)
        }
        Value::Path { nodes, edges } => {
            let node_terms: Vec<Term<'a>> =
                nodes.iter().map(|v| value_to_term(env, v)).collect();
            let edge_terms: Vec<Term<'a>> =
                edges.iter().map(|v| value_to_term(env, v)).collect();
            let pairs = vec![
                ("nodes".encode(env), node_terms.encode(env)),
                ("edges".encode(env), edge_terms.encode(env)),
            ];
            Term::map_from_pairs(env, &pairs).unwrap_or_else(|_| atoms::nil().encode(env))
        }
        // For temporal types, use Display formatting
        _ => format!("{}", value).encode(env),
    }
}

/// Convert a Grafeo BTreeMap to an Elixir map.
fn map_to_term<'a>(
    env: Env<'a>,
    map: &BTreeMap<grafeo_common::types::PropertyKey, Value>,
) -> Term<'a> {
    let pairs: Vec<(Term<'a>, Term<'a>)> = map
        .iter()
        .map(|(k, v)| (format!("{}", k).encode(env), value_to_term(env, v)))
        .collect();
    Term::map_from_pairs(env, &pairs).unwrap_or_else(|_| atoms::nil().encode(env))
}

rustler::init!("Elixir.Cqr.Grafeo.Native");
