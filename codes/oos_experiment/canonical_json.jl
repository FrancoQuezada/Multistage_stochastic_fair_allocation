# =====================================================================================
# Canonical JSON serialization, a matching minimal parser, and a stable content digest.
#
# WHY THIS EXISTS SEPARATELY FROM `output.jl`
#
# `output.jl` already writes JSON for `experiment_config.json`. That writer serves human
# inspection of a campaign and is free to evolve. The structural-instance manifest, by contrast,
# carries a *byte-reproducibility contract*: the same logical design must produce the same bytes
# and the same `ManifestID` in any process, and a manifest digest must not silently change
# because an unrelated reporting field changed how `experiment_config.json` is laid out.
#
# So the manifest gets its own pinned serializer, versioned by
# `OOS_CANONICAL_JSON_VERSION`. Changing the layout is therefore an explicit, visible act:
# the version string moves and every recorded digest changes with it.
#
# Determinism rules honoured here:
#   * object keys are emitted in ascending byte order, never in `Dict` iteration order;
#   * numbers use Julia's shortest round-trip representation, which is value-determined;
#   * no timestamp, path, hostname, process or locale-dependent value is ever produced;
#   * a value whose type has no canonical rendering is REFUSED, never stringified silently;
#   * Julia's built-in `hash` is never used. Not because it is salted — it is not — but because
#     it carries no stability contract across Julia versions or architectures, and a digest that
#     is persisted to disk and compared later needs one.
#
# The parser accepts exactly the grammar this writer emits (standard JSON), which is what lets
# the standalone manifest validator read a saved manifest with no package dependency. The
# repository has no JSON package in `Project.toml`, and Stage 2 must not add one.
# =====================================================================================

const OOS_CANONICAL_JSON_VERSION = "canonical_json_v1"

"""Name and version of the digest used for every manifest and structural identifier."""
const OOS_STABLE_DIGEST_ALGORITHM = "fnv1a64_v1"

# -------------------------------------------------------------------------------------
# Writer
# -------------------------------------------------------------------------------------

function _canonical_json_escape(text::AbstractString)
    out = IOBuffer()
    for character in String(text)
        if character == '"'
            write(out, "\\\"")
        elseif character == '\\'
            write(out, "\\\\")
        elseif character == '\n'
            write(out, "\\n")
        elseif character == '\r'
            write(out, "\\r")
        elseif character == '\t'
            write(out, "\\t")
        elseif character < ' '
            write(out, "\\u", string(UInt16(character), base=16, pad=4))
        else
            write(out, character)
        end
    end
    return String(take!(out))
end

"""
Canonical scalar rendering.

`Integer` and `Bool` are exact. `AbstractFloat` uses the shortest round-trip decimal, which is a
function of the value alone; a non-finite value is refused rather than silently written as
`null`, because a manifest must never record an unusable number.

Any other type is REFUSED. Stringifying an unexpected value would be the dangerous behaviour: a
`Tuple`, `NamedTuple`, `Matrix` or `missing` would become a plausible-looking quoted string that
no reader could interpret, and a `Set` would be rendered in iteration order and so break byte
reproducibility. Enum values must be converted with `string(...)` by the payload builder, which
also documents that they are recorded by canonical label rather than by integer value.
"""
function _canonical_json_scalar(value)
    value === nothing && return "null"
    value isa Bool && return value ? "true" : "false"
    value isa Integer && return string(value)
    if value isa AbstractFloat
        isfinite(value) || error(
            "El manifiesto canónico no admite valores no finitos; se recibió $value."
        )
        return string(Float64(value))
    end
    value isa Symbol && return "\"$(_canonical_json_escape(string(value)))\""
    value isa AbstractString && return "\"$(_canonical_json_escape(value))\""
    return error(
        "El escritor canónico no admite valores de tipo $(typeof(value)) " *
        "(se recibió: $value). Conviértelo explícitamente a String, Int, Float64 o Bool en el " *
        "constructor del payload; una conversión implícita produciría una cadena que ningún " *
        "lector podría interpretar, o un orden de iteración no reproducible."
    )
end

"""
Render `value` as canonical JSON.

Objects are keyed by `String` and emitted in ascending byte order. Arrays keep their given
order, which is why every caller must hand over an already canonically ordered vector.
"""
function canonical_json(value, indent::Int=0)
    pad = repeat("  ", indent)
    inner = repeat("  ", indent + 1)
    if value isa AbstractDict
        isempty(value) && return "{}"
        keys_sorted = sort([String(string(k)) for k in keys(value)])
        length(unique(keys_sorted)) == length(keys_sorted) || error(
            "Claves duplicadas tras la normalización canónica: $keys_sorted."
        )
        lookup = Dict(String(string(k)) => v for (k, v) in value)
        body = join(
            ["$inner\"$(_canonical_json_escape(k))\": $(canonical_json(lookup[k], indent + 1))"
             for k in keys_sorted],
            ",\n",
        )
        return "{\n$body\n$pad}"
    elseif value isa AbstractVector
        isempty(value) && return "[]"
        if any(item -> item isa AbstractDict || item isa AbstractVector, value)
            body = join(["$inner$(canonical_json(item, indent + 1))" for item in value], ",\n")
            return "[\n$body\n$pad]"
        end
        return "[" * join((_canonical_json_scalar(item) for item in value), ", ") * "]"
    end
    return _canonical_json_scalar(value)
end

# -------------------------------------------------------------------------------------
# Stable digest
# -------------------------------------------------------------------------------------

"""
64-bit FNV-1a digest of a byte string, rendered as 16 lowercase hex characters.

Written out here so it is identical in every Julia version, architecture and process. `Base.hash`
would not do: it carries no documented stability contract, so a digest persisted today could
differ after an upgrade. It mirrors the arithmetic of `deterministic_seed` in
`codes/parametersMS.jl` and of `oos_stream_seed`, so the repository has one documented digest
family rather than three.

This is an IDENTITY digest, not a tamper-evidence claim: FNV-1a is not a cryptographic hash. It
answers "is this the same manifest?", not "has an adversary altered this manifest?".
"""
function oos_stable_digest(text::AbstractString)
    accumulator = UInt64(0xcbf29ce484222325)
    for byte in codeunits(String(text))
        accumulator = (accumulator ⊻ UInt64(byte)) * UInt64(0x100000001b3)
    end
    return string(accumulator, base=16, pad=16)
end

"""
Digest of an ordered list of identity components.

The components are serialized through the canonical writer before hashing, so the encoding is
unambiguous: a string containing a separator character can never be confused with two
components, and a nested vector is delimited explicitly.
"""
oos_identity_digest(parts::AbstractVector) = oos_stable_digest(canonical_json(parts))

# -------------------------------------------------------------------------------------
# Parser
# -------------------------------------------------------------------------------------

"""
Parse the canonical JSON produced by `canonical_json`.

Deliberately minimal: objects become `Dict{String,Any}`, arrays become `Vector{Any}`, integers
become `Int`, other numbers become `Float64`. It exists so the standalone manifest validator can
read a saved manifest without adding a package dependency, and it refuses anything it does not
fully understand instead of guessing.
"""
function canonical_json_parse(text::AbstractString)
    data = String(text)
    value, position = _parse_value(data, _skip_space(data, 1))
    position = _skip_space(data, position)
    position > lastindex(data) || error(
        "Contenido JSON sobrante en la posición $position: $(data[position:min(end, position + 30)])"
    )
    return value
end

function _skip_space(data::String, position::Int)
    while position <= lastindex(data) && isspace(data[position])
        position = nextind(data, position)
    end
    return position
end

function _expect(data::String, position::Int, character::Char)
    position <= lastindex(data) && data[position] == character || error(
        "Se esperaba '$character' en la posición $position del JSON canónico."
    )
    return nextind(data, position)
end

function _parse_value(data::String, position::Int)
    position <= lastindex(data) || error("JSON canónico truncado.")
    character = data[position]
    character == '{' && return _parse_object(data, position)
    character == '[' && return _parse_array(data, position)
    character == '"' && return _parse_string(data, position)
    if startswith(SubString(data, position), "true")
        return (true, position + 4)
    elseif startswith(SubString(data, position), "false")
        return (false, position + 5)
    elseif startswith(SubString(data, position), "null")
        return (nothing, position + 4)
    end
    return _parse_number(data, position)
end

function _parse_object(data::String, position::Int)
    position = _expect(data, position, '{')
    result = Dict{String,Any}()
    position = _skip_space(data, position)
    if position <= lastindex(data) && data[position] == '}'
        return (result, nextind(data, position))
    end
    while true
        position = _skip_space(data, position)
        key, position = _parse_string(data, position)
        haskey(result, key) && error("Clave JSON duplicada: $key.")
        position = _skip_space(data, position)
        position = _expect(data, position, ':')
        position = _skip_space(data, position)
        value, position = _parse_value(data, position)
        result[key] = value
        position = _skip_space(data, position)
        position <= lastindex(data) || error("Objeto JSON truncado.")
        if data[position] == ','
            position = nextind(data, position)
        else
            position = _expect(data, position, '}')
            return (result, position)
        end
    end
end

function _parse_array(data::String, position::Int)
    position = _expect(data, position, '[')
    result = Any[]
    position = _skip_space(data, position)
    if position <= lastindex(data) && data[position] == ']'
        return (result, nextind(data, position))
    end
    while true
        position = _skip_space(data, position)
        value, position = _parse_value(data, position)
        push!(result, value)
        position = _skip_space(data, position)
        position <= lastindex(data) || error("Arreglo JSON truncado.")
        if data[position] == ','
            position = nextind(data, position)
        else
            position = _expect(data, position, ']')
            return (result, position)
        end
    end
end

function _parse_string(data::String, position::Int)
    position = _expect(data, position, '"')
    out = IOBuffer()
    while true
        position <= lastindex(data) || error("Cadena JSON truncada.")
        character = data[position]
        if character == '"'
            return (String(take!(out)), nextind(data, position))
        elseif character == '\\'
            position = nextind(data, position)
            position <= lastindex(data) || error("Escape JSON truncado.")
            escaped = data[position]
            if escaped == 'n'
                write(out, '\n')
            elseif escaped == 'r'
                write(out, '\r')
            elseif escaped == 't'
                write(out, '\t')
            elseif escaped == 'b'
                write(out, '\b')
            elseif escaped == 'f'
                write(out, '\f')
            elseif escaped == '"' || escaped == '\\' || escaped == '/'
                write(out, escaped)
            elseif escaped == 'u'
                length(data) >= position + 4 || error("Escape \\u JSON truncado.")
                code = parse(UInt16, data[(position+1):(position+4)]; base=16)
                write(out, Char(code))
                position += 4
            else
                error("Escape JSON no soportado: \\$escaped.")
            end
            position = nextind(data, position)
        else
            write(out, character)
            position = nextind(data, position)
        end
    end
end

function _parse_number(data::String, position::Int)
    start = position
    if position <= lastindex(data) && (data[position] == '-' || data[position] == '+')
        position = nextind(data, position)
    end
    integral = true
    while position <= lastindex(data)
        character = data[position]
        if isdigit(character)
            position = nextind(data, position)
        elseif character in ('.', 'e', 'E', '+', '-')
            integral = false
            position = nextind(data, position)
        else
            break
        end
    end
    token = data[start:prevind(data, position)]
    isempty(token) && error("Número JSON vacío en la posición $start.")
    if integral
        parsed = tryparse(Int, token)
        parsed === nothing || return (parsed, position)
    end
    parsed = tryparse(Float64, token)
    parsed === nothing && error("Número JSON inválido: $token.")
    return (parsed, position)
end

# -------------------------------------------------------------------------------------
# Atomic write
# -------------------------------------------------------------------------------------

"""
Write `text` to `path` atomically, through a temporary file in the destination directory.

A validator must never observe a half-written manifest, and an interrupted generation must never
leave a truncated file that a later run would treat as a conflicting manifest.
"""
function write_atomically(path::AbstractString, text::AbstractString)
    directory = dirname(abspath(String(path)))
    mkpath(directory)
    temporary = joinpath(directory, ".tmp_" * basename(String(path)) * "_" * string(getpid()))
    try
        open(temporary, "w") do io
            write(io, text)
        end
        mv(temporary, String(path); force=true)
    finally
        isfile(temporary) && rm(temporary; force=true)
    end
    return String(path)
end
