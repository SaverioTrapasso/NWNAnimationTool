# Adapted from SWLOR_NWN tooling; see LICENSE-SWLOR.txt.
from __future__ import annotations
from pathlib import Path
import struct
STOCK_MODEL_RESOURCE_TYPE = 2002
STOCK_KEY_ARCHIVES = (
    "nwn_base.key",
    "nwn_base_loc.key",
    "nwn_retail.key",
    "nwn_retail_loc.key",
    "xp1.key",
    "xp1_loc.key",
    "xp1patch.key",
    "xp1patch_loc.key",
    "xp2.key",
    "xp2_loc.key",
    "xp2patch.key",
    "xp2patch_loc.key",
    "xp3.key",
    "xp3_loc.key",
    "xp3patch.key",
    "xp3patch_loc.key",
)

def read_stock_key_models(data_directory: Path) -> dict[str, tuple[Path, int]]:
    """Index stock MDLs from the game's KEY/BIF layer in engine precedence order."""
    return read_stock_key_resources(data_directory, STOCK_MODEL_RESOURCE_TYPE)

def read_stock_key_resources(data_directory: Path, expected_type: int) -> dict[str, tuple[Path, int]]:
    """Index one resource type without changing the engine's archive precedence."""
    resources: dict[str, tuple[Path, int]] = {}
    install_root = data_directory.parent

    for archive_name in STOCK_KEY_ARCHIVES:
        key_path = data_directory / archive_name
        if not key_path.is_file():
            continue

        data = key_path.read_bytes()
        if len(data) < 64 or data[:4] != b"KEY ":
            raise RuntimeError(f"Invalid NWN KEY archive: {key_path}")

        bif_count, resource_count, bif_offset, resource_offset = struct.unpack_from(
            "<IIII", data, 8
        )
        if bif_offset + bif_count * 12 > len(data):
            raise RuntimeError(f"Truncated BIF table in {key_path}")
        if resource_offset + resource_count * 22 > len(data):
            raise RuntimeError(f"Truncated resource table in {key_path}")

        bif_paths: list[Path] = []
        for index in range(bif_count):
            _, filename_offset, filename_size, _ = struct.unpack_from(
                "<IIHH", data, bif_offset + index * 12
            )
            if filename_offset + filename_size > len(data):
                raise RuntimeError(f"Truncated BIF filename in {key_path}")
            filename = data[filename_offset : filename_offset + filename_size]
            filename = filename.split(b"\0", 1)[0].decode("ascii", errors="strict")
            normalized = Path(filename.replace("\\", "/"))
            candidate = install_root.joinpath(*normalized.parts)
            if not candidate.is_file():
                candidate = data_directory / normalized.name
            bif_paths.append(candidate)

        for index in range(resource_count):
            offset = resource_offset + index * 22
            resref = data[offset : offset + 16].split(b"\0", 1)[0].decode(
                "ascii", errors="strict"
            ).lower()
            resource_type, resource_id = struct.unpack_from("<HI", data, offset + 16)
            if resource_type != expected_type:
                continue
            bif_index = resource_id >> 20
            variable_index = resource_id & 0x000F_FFFF
            if bif_index >= len(bif_paths):
                raise RuntimeError(
                    f"Stock model '{resref}' references missing BIF {bif_index} in {key_path}"
                )
            resources[resref] = (bif_paths[bif_index], variable_index)

    if not resources:
        raise RuntimeError(
            f"No stock resources of type {expected_type} were indexed under {data_directory}"
        )
    return resources

def extract_stock_bif_resource(path: Path, variable_index: int, expected_type: int = STOCK_MODEL_RESOURCE_TYPE) -> bytes:
    with path.open("rb") as stream:
        header = stream.read(20)
        if len(header) != 20 or header[:4] != b"BIFF":
            raise RuntimeError(f"Invalid NWN BIF archive: {path}")
        variable_count, _, variable_offset = struct.unpack_from("<III", header, 8)
        if variable_index >= variable_count:
            raise RuntimeError(
                f"BIF resource index {variable_index} is outside {path}"
            )

        stream.seek(variable_offset + variable_index * 16)
        entry = stream.read(16)
        if len(entry) != 16:
            raise RuntimeError(f"Truncated BIF resource table in {path}")
        _, data_offset, data_size, resource_type = struct.unpack("<IIII", entry)
        if resource_type != expected_type:
            raise RuntimeError(
                f"BIF resource {variable_index} in {path} is not type {expected_type}"
            )
        stream.seek(data_offset)
        payload = stream.read(data_size)
        if len(payload) != data_size:
            raise RuntimeError(f"Truncated BIF model payload in {path}")
        return payload
