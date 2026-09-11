--[[
	Shared constants for Shadowed Unit Frames.

	DebuffTypeColor was removed as a global in the modern (11.x) client engine that the
	TBC Anniversary realms run on, so fall back to a local copy of the standard colors.
	Defined once here and consumed by the auras, health, and highlight modules.
]]
ShadowUF = select(2, ...)

ShadowUF.DebuffTypeColor = DebuffTypeColor or {
	none    = { r = 0.80, g = 0.00, b = 0.00 },
	Magic   = { r = 0.20, g = 0.60, b = 1.00 },
	Curse   = { r = 0.60, g = 0.00, b = 1.00 },
	Disease = { r = 0.60, g = 0.40, b = 0.00 },
	Poison  = { r = 0.00, g = 0.60, b = 0.00 },
}
ShadowUF.DebuffTypeColor[""] = ShadowUF.DebuffTypeColor[""] or ShadowUF.DebuffTypeColor.none
