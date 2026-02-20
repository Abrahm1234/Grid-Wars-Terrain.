extends Resource
class_name ErosionZoneConfig

@export var enabled: bool = true
@export_enum("rain_gullies", "alluvial_fan", "river_carve") var preset: String = "rain_gullies"
@export var center_xz: Vector2 = Vector2.ZERO
@export_range(0.0, 5000.0, 1.0, "or_greater") var radius_m: float = 200.0
@export_range(0.0, 5000.0, 1.0, "or_greater") var feather_m: float = 50.0
