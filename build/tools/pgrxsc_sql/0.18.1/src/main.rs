//! Emit a pgrx extension's SQL by reading it out of the built cdylib.
//!
//! pgrx >= 0.18 records the crate's SQL entity graph in a `.pgrxsc` link
//! section, so the schema can be recovered from the library as data. The
//! upstream route, `cargo pgrx schema`, instead dlopens the library and runs
//! code out of it, which a network-less sandbox cannot allow and a
//! cross-compile cannot do at all. This only ever reads the file.
//!
//!     pgrxsc-sql <lib.so> <ext.control> <extname> <version>

use eyre::{eyre, Result};
use object::{Object, ObjectSection};
use pgrx_sql_entity_graph::section::decode_entities;
use pgrx_sql_entity_graph::{ControlFile, PgrxSql, SqlGraphEntity};

const USAGE: &str = "usage: pgrxsc-sql <lib.so> <ext.control> <extname> <version>";

fn main() -> Result<()> {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let [so_path, control_path, extname, version] = args.as_slice() else {
        return Err(eyre!(USAGE));
    };

    let data = std::fs::read(so_path)?;
    let section = object::File::parse(&*data)?
        .section_by_name(".pgrxsc")
        .ok_or_else(|| eyre!("no .pgrxsc section in {so_path}"))?
        .data()?
        .to_vec();

    eprintln!("read .pgrxsc: {} bytes from {so_path}", section.len());

    // The control file is the graph's root: it carries the extension's
    // requires / schema / relocatability, and `@CARGO_VERSION@` in it resolves
    // to the crate version, the same substitution the installed control gets.
    let control = ControlFile::from_path_with_cargo_version(control_path, version)?;
    let mut entities = vec![SqlGraphEntity::ExtensionRoot(control)];
    entities.extend(decode_entities(&section)?);

    eprintln!("decoded {} entities", entities.len());

    PgrxSql::build(entities.into_iter(), extname.clone(), false)?
        .write(&mut std::io::stdout())?;

    Ok(())
}
