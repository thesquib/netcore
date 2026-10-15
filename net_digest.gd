class_name NetDigest
extends RefCounted
## Helpers for a game's content digest: a short hash of the data both sides of a game must
## share. The hash covers file paths and bytes, so line endings count (keep data files LF).


## A 12-hex-digit SHA-256 of {path: bytes}, in path order.
static func of(files: Dictionary) -> String:
	var keys := files.keys()
	keys.sort()
	var h := HashingContext.new()
	h.start(HashingContext.HASH_SHA256)
	for k in keys:
		h.update(String(k).to_utf8_buffer())
		h.update(files[k])
	return h.finish().hex_encode().left(12)


## {path: bytes} of the files under `dir` (recursively) ending in `suffix`, leaving out `skip`.
static func read_files(dir: String, suffix := ".json", skip: Array = []) -> Dictionary:
	var files := {}
	for path in list_files(dir, suffix):
		if not path in skip:
			files[path] = FileAccess.get_file_as_bytes(path)
	return files


static func list_files(dir: String, suffix := ".json") -> Array:
	var out := []
	if not DirAccess.dir_exists_absolute(dir):
		return out
	for f in DirAccess.get_files_at(dir):
		if f.ends_with(suffix):
			out.append(dir.path_join(f))
	for d in DirAccess.get_directories_at(dir):
		out.append_array(list_files(dir.path_join(d), suffix))
	return out
