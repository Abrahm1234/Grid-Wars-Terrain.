@tool
extends EditorScript

const ARRAY_PATH := "res://Textures/biome_texture_array.tres"
const SOURCE_DIR := "res://Textures/biomes"

const BIOME_FILES := [
	"00_ocean.png",
	"01_beach.png",
	"02_scorched.png",
	"03_bare.png",
	"04_tundra.png",
	"05_snow.png",
	"06_temp_desert.png",
	"07_shrubland.png",
	"08_taiga.png",
	"09_grass.png",
	"10_t_decid.png",
	"11_t_rain.png",
	"12_s_desert.png",
	"13_trop_seasonal.png",
	"14_trop_rain.png"
]

const SIDE_VARIANTS := [
	{
		"suffix": "_sidex.png",
		"tint": Color(0.78, 0.74, 0.70, 1.0),
		"brightness": 0.90
	},
	{
		"suffix": "_sidez.png",
		"tint": Color(0.66, 0.63, 0.60, 1.0),
		"brightness": 0.80
	}
]

func _run() -> void:
	var images: Array[Image] = []
	var first_image: Image = null

	for file in BIOME_FILES:
		var path: String = SOURCE_DIR.path_join(file)
		var top_img: Image = _load_image_resource(path)
		if top_img == null:
			return

		if first_image == null:
			first_image = top_img.duplicate()
		else:
			if top_img.get_width() != first_image.get_width() or top_img.get_height() != first_image.get_height():
				push_error("Image %s dimensions %dx%d do not match %dx%d." % [
					path, top_img.get_width(), top_img.get_height(), first_image.get_width(), first_image.get_height()
				])
				return
			if top_img.get_format() != first_image.get_format():
				push_error("Image %s format %s does not match %s." % [
					path, str(top_img.get_format()), str(first_image.get_format())
				])
				return

		images.append(top_img)

		var stem: String = file.get_basename()
		for variant in SIDE_VARIANTS:
			var suffix: String = variant["suffix"]
			var tint: Color = variant["tint"]
			var brightness: float = variant["brightness"]

			var side_path: String = SOURCE_DIR.path_join("%s%s" % [stem, suffix])
			var side_img: Image = null
			if FileAccess.file_exists(side_path):
				side_img = _load_image_resource(side_path)
				if side_img == null:
					return

				if side_img.get_width() != first_image.get_width() or side_img.get_height() != first_image.get_height():
					push_error("Side image %s dimensions %dx%d do not match %dx%d." % [
						side_path, side_img.get_width(), side_img.get_height(), first_image.get_width(), first_image.get_height()
					])
					return
				if side_img.get_format() != first_image.get_format():
					push_error("Side image %s format %s does not match %s." % [
						side_path, str(side_img.get_format()), str(first_image.get_format())
					])
					return
			else:
				side_img = _generate_side_variant(top_img, tint, brightness)

			images.append(side_img)

	if images.size() != BIOME_FILES.size() * 3:
		push_error("Unexpected layer count %d (expected %d)." % [images.size(), BIOME_FILES.size() * 3])
		return

	var tex_array := Texture2DArray.new()
	var create_err := tex_array.create_from_images(images)
	if create_err != OK:
		push_error("Texture array creation failed (error %d)" % create_err)
		return

	var save_err := ResourceSaver.save(tex_array, ARRAY_PATH)
	if save_err != OK:
		push_error("Failed to save %s (error %d)" % [ARRAY_PATH, save_err])
	else:
		print("Biome texture array rebuilt at %s" % ARRAY_PATH)

func _generate_side_variant(src: Image, tint: Color, brightness: float) -> Image:
	var side: Image = src.duplicate()
	side.convert(Image.FORMAT_RGBA8)
	for y in range(side.get_height()):
		for x in range(side.get_width()):
			var c: Color = side.get_pixel(x, y)
			var lum: float = c.r * 0.299 + c.g * 0.587 + c.b * 0.114
			var v: float = clamp(lum * brightness, 0.0, 1.0)
			var out_col: Color = Color(
				clamp(v * tint.r, 0.0, 1.0),
				clamp(v * tint.g, 0.0, 1.0),
				clamp(v * tint.b, 0.0, 1.0),
				c.a
			)
			side.set_pixel(x, y, out_col)
	return side

func _load_image_resource(path: String) -> Image:
	if not ResourceLoader.exists(path):
		push_error("Missing biome texture resource: %s" % path)
		return null

	var res: Resource = ResourceLoader.load(path)
	if res == null:
		push_error("Failed to load resource %s" % path)
		return null

	var img: Image = null
	if res is Texture2D:
		img = (res as Texture2D).get_image()
	elif res is Image:
		img = res as Image
	else:
		push_error("Resource %s is not a Texture2D or Image." % path)
		return null

	if img == null:
		push_error("Resource %s returned a null Image." % path)
		return null

	var copy: Image = img.duplicate()
	copy.convert(Image.FORMAT_RGBA8)
	return copy
