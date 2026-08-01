package dev.monogres.monobot.postgres.extensions.control;

import com.fasterxml.jackson.annotation.JsonAnyGetter;
import com.fasterxml.jackson.annotation.JsonAnySetter;
import com.fasterxml.jackson.annotation.JsonInclude;
import com.fasterxml.jackson.annotation.JsonProperty;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.annotation.JsonDeserialize;
import dev.monogres.monobot.json.CsvStringArrayDeserializer;
import io.quarkus.runtime.annotations.RegisterForReflection;
import java.util.Map;

/// Java record modeling the fields, defaults and invariants of a Postgres extension's control
/// ($extname.control) file.
///
/// See: [Extension Files](https://www.postgresql.org/docs/current/extend-extensions.html)
@RegisterForReflection
public record Control(
    /// The directory containing the extension's SQL script file(s). Unless an absolute path is
    /// given, the name is relative to the installation's SHAREDIR directory. The default behavior
    /// is equivalent to specifying directory = 'extension'.
    String directory,

    /// The default version of the extension (the one that will be installed if no version is
    /// specified in CREATE EXTENSION). Although this can be omitted, that will result in CREATE
    /// EXTENSION failing if no VERSION option appears, so you generally don't want to do that.
    @JsonProperty("default_version") String defaultVersion,

    /// A comment (any string) about the extension. The comment is applied when initially creating
    /// an extension, but not during extension updates (since that might override user-added
    /// comments). Alternatively, the extension's comment can be set by writing a COMMENT command in
    /// the script file.
    String comment,

    /// The character set encoding used by the script file(s). This should be specified if the
    /// script files contain any non-ASCII characters. Otherwise the files will be assumed to be in
    /// the database encoding.
    String encoding,

    /// The value of this parameter will be substituted for each occurrence of MODULE_PATHNAME in
    /// the script file(s). If it is not set, no substitution is made. Typically, this is set to
    /// $libdir/shared_library_name and then MODULE_PATHNAME is used in CREATE FUNCTION commands for
    /// C-language functions, so that the script files do not need to hard-wire the name of the
    /// shared library.
    @JsonProperty("module_pathname") String modulePathname,

    /// A list of names of extensions that this extension depends on, for example requires = 'foo,
    /// bar'. Those extensions must be installed before this one can be installed.
    @JsonDeserialize(using = CsvStringArrayDeserializer.class) String[] requires,

    /// A list of names of extensions that this extension depends on that should be barred from
    /// changing their schemas via ALTER EXTENSION ... SET SCHEMA. This is needed if this
    /// extension's script references the name of a required extension's schema (using the
    /// @extschema:name@ syntax) in a way that cannot track renames.
    @JsonDeserialize(using = CsvStringArrayDeserializer.class) @JsonProperty("no_relocate")
        String[] noRelocate,

    /// If this parameter is true (which is the default), only superusers can create the extension
    /// or update it to a new version (but see also trusted, below). If it is set to false, just the
    /// privileges required to execute the commands in the installation or update script are
    /// required. This should normally be set to true if any of the script commands require
    /// superuser privileges. (Such commands would fail anyway, but it's more user-friendly to give
    /// the error up front.)
    Boolean superuser,

    /// This parameter, if set to true (which is not the default), allows some non-superusers to
    /// install an extension that has superuser set to true. Specifically, installation will be
    /// permitted for anyone who has CREATE privilege on the current database. When the user
    /// executing CREATE EXTENSION is not a superuser but is allowed to install by virtue of this
    /// parameter, then the installation or update script is run as the bootstrap superuser, not as
    /// the calling user. This parameter is irrelevant if superuser is false. Generally, this should
    /// not be set true for extensions that could allow access to otherwise-superuser-only
    /// abilities, such as file system access. Also, marking an extension trusted requires
    /// significant extra effort to write the extension's installation and update script(s)
    /// securely; see Section 36.17.6.
    Boolean trusted,

    /// An extension is relocatable if it is possible to move its contained objects into a different
    /// schema after initial creation of the extension. The default is false, i.e., the extension is
    /// not relocatable. See Section 36.17.2 for more information.
    Boolean relocatable,

    /// This parameter can only be set for non-relocatable extensions. It forces the extension to be
    /// loaded into exactly the named schema and not any other. The schema parameter is consulted
    /// only when initially creating an extension, not during extension updates. See Section 36.17.2
    /// for more information.
    String schema,

    /// Every directive of the file this record does not model, written back out beside the ones it
    /// does. Postgres adds directives from release to release and an archive is read once and
    /// catalogued for good, so a directive that arrives before this record knows the name of it is
    /// still something the upstream declared about that version.
    @JsonAnySetter @JsonAnyGetter Map<String, String> extra) {
  public Control {
    if (extra == null) {
      extra = Map.of();
    }

    // Set proper defaults for boolean fields
    if (superuser == null) {
      superuser = true;
    }
    if (trusted == null) {
      trusted = false;
    }
    if (relocatable == null) {
      relocatable = false;
    }

    // Enforce invariants
    if (schema != null && relocatable) {
      throw new RuntimeException("schema can only be set for non-relocatable extensions");
    }
  }

  public static Control fromBytes(byte[] bytes) {
    var mapper = new ObjectMapper().setDefaultPropertyInclusion(JsonInclude.Include.NON_NULL);

    return mapper.convertValue(ControlParser.parse(bytes), Control.class);
  }
}
