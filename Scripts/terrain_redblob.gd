# res://Scripts/terrain_redblob.gd
class_name TerrainRedBlob
extends RefCounted

enum IslandMode { NONE, SQUARE_BUMP, EUCLIDEAN2 }

enum Biome {
	OCEAN,
	BEACH,
	SCORCHED,
	BARE,
	TUNDRA,
	SNOW,
	TEMP_DESERT,
	SHRUBLAND,
	TAIGA,
	GRASS,
	T_DECID,
	T_RAIN,
	S_DESERT,
	TROP_SEASONAL,
	TROP_RAIN
}

# --- Elevation thresholds (normalized 0..1) ---
# Sea level (only OCEAN uses elevation directly)
const ELEV_OCEAN_MAX: float = 0.08

# Elevation bands
const ELEV_MIDLAND_MIN: float = 0.32
const ELEV_UPLAND_MIN: float = 0.58
const ELEV_MOUNTAIN_MIN: float = 0.78

# Highest elevations are always snow
const ELEV_SNOWLINE_MIN: float = 0.92

# Beach behavior: thickness in tiles around ocean
const BEACH_THICKNESS_TILES: int = 1  # 1 = thin wrap, 2 = thicker

# Biome order by elevation (lowest -> highest). Beach is a shoreline overlay.
const BIOME_ORDER: Array[int] = [
	Biome.OCEAN,
	Biome.BEACH,

	# Lowlands
	Biome.S_DESERT,
	Biome.TROP_RAIN,
	Biome.TROP_SEASONAL,

	# Midlands
	Biome.TEMP_DESERT,
	Biome.GRASS,
	Biome.T_DECID,
	Biome.T_RAIN,

	# Uplands
	Biome.SHRUBLAND,
	Biome.TAIGA,

	# Mountains -> summit
	Biome.TUNDRA,
	Biome.BARE,
	Biome.SCORCHED,
	Biome.SNOW
]

const BIOME_COLORS: Dictionary = {
	Biome.OCEAN:         Color(84.0 / 255.0,  124.0 / 255.0, 139.0 / 255.0, 1.0),
	Biome.BEACH:         Color(233.0 / 255.0, 221.0 / 255.0, 202.0 / 255.0, 1.0),
	Biome.SCORCHED:      Color(85.0 / 255.0,   85.0 / 255.0,  85.0 / 255.0, 1.0),
	Biome.BARE:          Color(136.0 / 255.0, 136.0 / 255.0, 136.0 / 255.0, 1.0),
	Biome.TUNDRA:        Color(187.0 / 255.0, 187.0 / 255.0, 170.0 / 255.0, 1.0),
	Biome.SNOW:          Color(240.0 / 255.0, 248.0 / 255.0, 255.0 / 255.0, 1.0),
	Biome.TEMP_DESERT:   Color(210.0 / 255.0, 185.0 / 255.0, 139.0 / 255.0, 1.0),
	Biome.SHRUBLAND:     Color(136.0 / 255.0, 153.0 / 255.0, 119.0 / 255.0, 1.0),
	Biome.TAIGA:         Color(153.0 / 255.0, 170.0 / 255.0, 136.0 / 255.0, 1.0),
	Biome.GRASS:         Color(136.0 / 255.0, 204.0 / 255.0, 136.0 / 255.0, 1.0),
	Biome.T_DECID:       Color(85.0 / 255.0,  170.0 / 255.0, 102.0 / 255.0, 1.0),
	Biome.T_RAIN:        Color(35.0 / 255.0,  69.0 / 255.0, 11.0 / 255.0, 1.0),
	Biome.S_DESERT:      Color(233.0 / 255.0, 196.0 / 255.0, 106.0 / 255.0, 1.0),
	Biome.TROP_SEASONAL: Color(76.0 / 255.0,  175.0 / 255.0,  80.0 / 255.0, 1.0),
	Biome.TROP_RAIN:     Color(18.0 / 255.0,  110.0 / 255.0,  69.0 / 255.0, 1.0)
}

const BIOME_NAMES: Dictionary = {
	Biome.OCEAN: "Ocean",
	Biome.BEACH: "Beach",
	Biome.SCORCHED: "Scorched",
	Biome.BARE: "Bare",
	Biome.TUNDRA: "Tundra",
	Biome.SNOW: "Snow",
	Biome.TEMP_DESERT: "Temperate Desert",
	Biome.SHRUBLAND: "Shrubland",
	Biome.TAIGA: "Taiga",
	Biome.GRASS: "Grassland",
	Biome.T_DECID: "Temperate Deciduous Forest",
	Biome.T_RAIN: "Temperate Rain Forest",
	Biome.S_DESERT: "Subtropical Desert",
	Biome.TROP_SEASONAL: "Tropical Seasonal Forest",
	Biome.TROP_RAIN: "Tropical Rain Forest"
}

static func get_biome_count() -> int:
	return BIOME_ORDER.size()

static func get_biome_order() -> Array[int]:
	return BIOME_ORDER.duplicate()

static func get_biome_name(id: int) -> String:
	return BIOME_NAMES.get(id, "Biome %d" % id)

static func gen_fields(
	size: Vector2i,
	rng_seed: int,
	freq_elev: float,
	freq_moist: float,
	octave_weights: PackedFloat32Array,
	exponent: float,
	fudge: float,
	island_mode: int,
	island_mix: float
) -> Dictionary:
	var sz := size
	if sz.x < 2 or sz.y < 2:
		sz = Vector2i(max(2, sz.x), max(2, sz.y))

	var elev: Image = Image.create(sz.x, sz.y, false, Image.FORMAT_RF)
	var moist: Image = Image.create(sz.x, sz.y, false, Image.FORMAT_RF)

	var n_e := FastNoiseLite.new()
	n_e.seed = rng_seed
	n_e.noise_type = FastNoiseLite.NoiseType.TYPE_SIMPLEX
	n_e.frequency = freq_elev

	var n_m := FastNoiseLite.new()
	n_m.seed = rng_seed ^ 0x9E3779B9
	n_m.noise_type = FastNoiseLite.NoiseType.TYPE_SIMPLEX
	n_m.frequency = freq_moist

	var offs: Array[Vector2] = [
		Vector2(0.0, 0.0), Vector2(5.3, 9.1), Vector2(17.8, 23.5),
		Vector2(31.7, -11.4), Vector2(-19.6, 42.2), Vector2(71.1, 13.3)
	]

	var wsum: float = 0.0
	for w in octave_weights:
		wsum += float(w)
	if wsum <= 0.0:
		wsum = 1.0

	for y in range(sz.y):
		var ny: float = float(y) / float(sz.y) - 0.5
		var den_y: float = max(1.0, float(sz.y - 1))
		var ny_is: float = 2.0 * float(y) / den_y - 1.0

		for x in range(sz.x):
			var nx: float = float(x) / float(sz.x) - 0.5
			var den_x: float = max(1.0, float(sz.x - 1))
			var nx_is: float = 2.0 * float(x) / den_x - 1.0

			# --- elevation ---
			var e: float = 0.0
			for i in range(min(octave_weights.size(), offs.size())):
				var f: float = pow(2.0, float(i))
				var o: Vector2 = offs[i]
				e += float(octave_weights[i]) * (0.5 * (n_e.get_noise_2d(nx * f + o.x, ny * f + o.y) + 1.0))
			e /= wsum
			e = pow(clamp(e * fudge, 0.0, 1.0), exponent)

			# islands (optional)
			if island_mode != IslandMode.NONE and island_mix > 0.0:
				var d: float
				if island_mode == IslandMode.SQUARE_BUMP:
					d = 1.0 - (1.0 - nx_is * nx_is) * (1.0 - ny_is * ny_is)
				else:
					d = min(1.0, (nx_is * nx_is + ny_is * ny_is) / sqrt(2.0))
				var shaped: float = 1.0 - d
				e = lerp(e, shaped, clamp(island_mix, 0.0, 1.0))

			# --- moisture ---
			var m: float = 0.0
			for i in range(min(octave_weights.size(), offs.size())):
				var f2: float = pow(2.0, float(i))
				var o2: Vector2 = offs[(i + 2) % offs.size()]
				m += float(octave_weights[i]) * (0.5 * (n_m.get_noise_2d(nx * f2 + o2.x, ny * f2 + o2.y) + 1.0))
			m /= wsum

			elev.set_pixel(x, y, Color(e, 0, 0))
			moist.set_pixel(x, y, Color(m, 0, 0))

	return {"elev": elev, "moist": moist}

static func make_biome_map(elev: Image, moist: Image) -> Image:
	return make_biome_layers(elev, moist)["color"]

static func make_biome_layers(elev: Image, moist: Image) -> Dictionary:
	assert(elev.get_size() == moist.get_size())
	var sz := elev.get_size()

	# Two-pass process: compute biomes (no beach), then wrap beaches around ocean.
	var biome_ids: Array[int] = []
	biome_ids.resize(sz.x * sz.y)

	# Pass 1: compute biomes (no beach)
	for y in range(sz.y):
		for x in range(sz.x):
			var e: float = elev.get_pixel(x, y).r
			var m: float = moist.get_pixel(x, y).r
			var e_q: float = floor(e * 12.0) / 12.0
			var m_q: float = floor(m * 12.0) / 12.0
			biome_ids[y * sz.x + x] = _select_biome_no_beach(e_q, m_q)

	# Pass 2: apply thin beach ring
	_apply_beach_ring(biome_ids, sz.x, sz.y, BEACH_THICKNESS_TILES)

	# Build images
	var color_img := Image.create(sz.x, sz.y, false, Image.FORMAT_RGBA8)
	var index_img := Image.create(sz.x, sz.y, false, Image.FORMAT_RF)

	for y in range(sz.y):
		for x in range(sz.x):
			var id: int = biome_ids[y * sz.x + x]
			color_img.set_pixel(x, y, _biome_color_for_id(id))
			index_img.set_pixel(x, y, Color(float(id), 0.0, 0.0))

	return {"color": color_img, "index": index_img}

static func _biome_color(e: float, m: float) -> Color:
	return _biome_color_for_id(_select_biome_no_beach(e, m))

static func _biome_color_for_id(id: int) -> Color:
	return BIOME_COLORS.get(id, Color(1.0, 0.0, 1.0, 1.0))

# Biome selection excluding beach. Beach is applied as a shoreline post-process.
static func _select_biome_no_beach(e: float, m: float) -> int:
	# Ocean
	if e < ELEV_OCEAN_MAX:
		return Biome.OCEAN

	# Guaranteed summit snow (highest elevations)
	if e >= ELEV_SNOWLINE_MIN:
		return Biome.SNOW

	# Mountains (below snowline)
	if e > ELEV_MOUNTAIN_MIN:
		if m < 0.15: return Biome.SCORCHED
		if m < 0.18: return Biome.BARE
		if m < 0.55: return Biome.TUNDRA
		return Biome.SNOW

	# Uplands / boreal
	if e > ELEV_UPLAND_MIN:
		if m < 0.35: return Biome.TEMP_DESERT
		if m < 0.57: return Biome.SHRUBLAND
		return Biome.TAIGA

	# Midlands
	if e > ELEV_MIDLAND_MIN:
		if m < 0.20: return Biome.TEMP_DESERT
		if m < 0.30: return Biome.GRASS
		if m < 0.62: return Biome.T_DECID
		return Biome.T_RAIN

	# Lowlands
	if m < 0.16: return Biome.S_DESERT
	if m < 0.36: return Biome.GRASS
	if m < 0.68: return Biome.TROP_SEASONAL
	return Biome.TROP_RAIN

# Convert land tiles within `thickness` steps of any ocean tile into BEACH.
# Uses 4-neighbor distance (no diagonals).
static func _apply_beach_ring(biome_ids: Array[int], w: int, h: int, thickness: int) -> void:
	if thickness <= 0:
		return

	# -1 = unvisited; otherwise number of steps to nearest ocean
	var dist: PackedInt32Array = PackedInt32Array()
	dist.resize(w * h)
	for i in range(w * h):
		dist[i] = -1

	var qx: PackedInt32Array = PackedInt32Array()
	var qy: PackedInt32Array = PackedInt32Array()

	# Seed BFS with all ocean tiles at distance 0
	for y in range(h):
		for x in range(w):
			var idx: int = y * w + x
			if biome_ids[idx] == Biome.OCEAN:
				dist[idx] = 0
				qx.append(x)
				qy.append(y)

	# BFS outward up to `thickness`
	var head: int = 0
	while head < qx.size():
		var x: int = qx[head]
		var y: int = qy[head]
		var idx: int = y * w + x
		var d: int = dist[idx]
		head += 1

		if d >= thickness:
			continue

		# 4-neighbors
		var n0: Vector2i = Vector2i(x + 1, y)
		var n1: Vector2i = Vector2i(x - 1, y)
		var n2: Vector2i = Vector2i(x, y + 1)
		var n3: Vector2i = Vector2i(x, y - 1)

		var ns: Array[Vector2i] = [n0, n1, n2, n3]
		for p: Vector2i in ns:
			if p.x < 0 or p.x >= w or p.y < 0 or p.y >= h:
				continue
			var nidx: int = p.y * w + p.x
			if dist[nidx] != -1:
				continue
			dist[nidx] = d + 1
			qx.append(p.x)
			qy.append(p.y)

	# Mark beaches: land tiles at distance 1..thickness from ocean.
	for i in range(w * h):
		if biome_ids[i] == Biome.OCEAN:
			continue
		var d2: int = dist[i]
		if d2 >= 1 and d2 <= thickness:
			biome_ids[i] = Biome.BEACH
