-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Asset references
local SFX = script.Parent

--------------------------------------------------------------------------------
-- Configuration
--------------------------------------------------------------------------------
local DEBUG          = false   -- flip to true during development for warnings
local POOL_SIZE      = 5       -- pre-warmed instances per unique sound asset
local POOL_MAX       = 16      -- hard ceiling per asset (prevents runaway growth)

--------------------------------------------------------------------------------
-- Types
--------------------------------------------------------------------------------
export type SoundOptions = {
	Volume:        number?,   -- default: source volume
	PlaybackSpeed: number?,   -- default: 1.0
	Looped:        boolean?,  -- default: source setting (pooled only when false)
	Pitch:         number?,   -- octave shift via PitchShiftSoundEffect
}

--------------------------------------------------------------------------------
-- Internal state
--------------------------------------------------------------------------------

--[[ Asset cache — built once, avoids repeated FindFirstChild.
     Key = sound name (string), Value = source Sound instance. ]]
local assetCache: { [string]: Sound } = {}

--[[ Object pool — per-asset stack of idle Sound instances.
     Key = sound name, Value = array used as a LIFO stack.
     LIFO keeps the most-recently-returned (warmest) instance on top. ]]
local pool: { [string]: { Sound } } = {}

--[[ Tracks the total number of instances allocated per asset
     (active + pooled) so we can enforce POOL_MAX. ]]
local allocCount: { [string]: number } = {}

--[[ Original property snapshots for fast reset on pool return.
     Key = sound name, Value = { Volume, PlaybackSpeed, Looped } ]]
local defaults: { [string]: { Volume: number, PlaybackSpeed: number, Looped: boolean } } = {}

--------------------------------------------------------------------------------
-- Cache & pool bootstrap
--------------------------------------------------------------------------------

--[[ Builds the asset lookup dictionary and pre-warms the pool.
     Called once at module load; safe to call again if SFX contents change. ]]
local function buildCache()
	table.clear(assetCache)

	for _, child in SFX:GetChildren() do
		if child:IsA("Sound") then
			local name = child.Name
			assetCache[name] = child
			defaults[name]   = {
				Volume        = child.Volume,
				PlaybackSpeed = child.PlaybackSpeed,
				Looped        = child.Looped,
			}

			-- Pre-warm pool
			if not pool[name] then
				pool[name]       = table.create(POOL_SIZE)
				allocCount[name] = 0
			end

			for _ = 1, POOL_SIZE do
				local inst     = child:Clone() :: Sound
				inst.Name      = name .. "_pooled"
				-- Pre-attach a disabled pitch effect so we never Instance.new at runtime
				local fx       = Instance.new("PitchShiftSoundEffect")
				fx.Enabled     = false
				fx.Parent      = inst
				-- Park outside the world — no spatial audio cost
				inst.Parent    = nil
				table.insert(pool[name], inst)
				allocCount[name] += 1
			end
		end
	end
end

buildCache()

--------------------------------------------------------------------------------
-- Pool internals
--------------------------------------------------------------------------------

--[[ Resets a pooled sound to its source defaults.
     Avoids touching properties that are already at default (skip-if-equal). ]]
local function resetSound(inst: Sound, name: string)
	local def = defaults[name]
	if not def then return end

	if inst.Volume        ~= def.Volume        then inst.Volume        = def.Volume        end
	if inst.PlaybackSpeed ~= def.PlaybackSpeed then inst.PlaybackSpeed = def.PlaybackSpeed end
	if inst.Looped        ~= def.Looped        then inst.Looped        = def.Looped        end

	-- Disable pitch effect rather than destroy it
	local fx = inst:FindFirstChildWhichIsA("PitchShiftSoundEffect")
	if fx and fx.Enabled then
		fx.Enabled = false
		fx.Octave  = 1
	end
end

--[[ Returns an instance to the pool after playback finishes.
     Validates the instance is still alive before reuse. ]]
local function returnToPool(inst: Sound, name: string)
	-- Guard: instance may have been destroyed externally
	if not inst.Parent and not inst:IsDescendantOf(game) then
		-- Instance was destroyed — adjust count, don't re-pool
		allocCount[name] = math.max(0, (allocCount[name] or 1) - 1)
		return
	end

	inst:Stop()
	inst.Parent = nil        -- un-parent: zero spatial cost while idle
	resetSound(inst, name)

	local bucket = pool[name]
	if bucket then
		table.insert(bucket, inst)
	end
end

--[[ Acquires an instance from the pool, or allocates a new one if the
     pool is empty and we haven't hit POOL_MAX.
     Returns nil only when the asset doesn't exist. ]]
local function acquire(name: string): Sound?
	local source = assetCache[name]
	if not source then
		if DEBUG then
			warn(("[Sound] Asset not found: '%s'"):format(name))
		end
		return nil
	end

	-- Try pool first (LIFO pop)
	local bucket = pool[name]
	if bucket then
		local inst = table.remove(bucket)  -- pop from end
		if inst then
			return inst
		end
	end

	-- Pool empty — allocate if under ceiling
	local count = allocCount[name] or 0
	if count < POOL_MAX then
		local inst  = source:Clone() :: Sound
		inst.Name   = name .. "_pooled"
		local fx    = Instance.new("PitchShiftSoundEffect")
		fx.Enabled  = false
		fx.Parent   = inst
		allocCount[name] = count + 1
		return inst
	end

	-- Hard ceiling reached — warn in debug, return nil
	if DEBUG then
		warn(("[Sound] Pool ceiling reached for '%s' (%d)"):format(name, POOL_MAX))
	end
	return nil
end

--------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------
local Sound = {}

--[[ Plays a sound by name.

     Non-looped sounds are drawn from the object pool and automatically
     returned when playback ends — zero Clone / Destroy overhead on the
     hot path.

     Looped sounds are cloned normally (lifetime is caller-controlled)
     and must be stopped / destroyed by the caller.

     @param soundName  Name of a child Sound under the SFX folder.
     @param parent     Where to parent the Sound (defaults to workspace).
     @param options    Optional overrides for volume, speed, pitch, loop.
     @return           The Sound instance, or nil on failure. ]]
	 
function Sound.PlaySound(soundName: string, parent: Instance?, options: SoundOptions?): Sound?
	local resolvedParent: Instance = parent or workspace

	if DEBUG and not parent then
		warn(("[Sound] No parent supplied for '%s' — defaulting to workspace."):format(soundName))
	end

	local wantsLoop = options and options.Looped

	---------------------------------------------------------------------------
	-- Looped path — clone (caller owns lifetime)
	---------------------------------------------------------------------------
	if wantsLoop then
		local source = assetCache[soundName]
		if not source then
			if DEBUG then
				warn(("[Sound] Asset not found: '%s'"):format(soundName))
			end
			return nil
		end

		local clone = source:Clone() :: Sound
		clone.Looped = true
		if options then
			if options.Volume        ~= nil then clone.Volume        = options.Volume        end
			if options.PlaybackSpeed ~= nil then clone.PlaybackSpeed = options.PlaybackSpeed end
			if options.Pitch         ~= nil then
				Instance.new("PitchShiftSoundEffect", clone).Octave = options.Pitch
			end
		end
		clone.Parent = resolvedParent
		clone:Play()
		return clone
	end

	---------------------------------------------------------------------------
	-- Non-looped path — pooled (zero-alloc hot path)
	---------------------------------------------------------------------------
	local inst = acquire(soundName)
	if not inst then return nil end

	-- Apply caller overrides
	if options then
		if options.Volume        ~= nil then inst.Volume        = options.Volume        end
		if options.PlaybackSpeed ~= nil then inst.PlaybackSpeed = options.PlaybackSpeed end
		if options.Pitch         ~= nil then
			local fx = inst:FindFirstChildWhichIsA("PitchShiftSoundEffect")
			if fx then
				fx.Octave  = options.Pitch
				fx.Enabled = true
			end
		end
	end

	inst.Parent = resolvedParent
	inst:Play()

	-- Auto-return on completion — :Once() auto-disconnects, no closure leak
	inst.Ended:Once(function()
		returnToPool(inst, soundName)
	end)

	return inst
end

--[[ Stops a sound and returns it to the pool immediately.
     Safe to call on both pooled and cloned (looped) sounds. ]]
function Sound.StopSound(inst: Sound?)
	if not inst then return end

	-- Looped / non-pooled instances just get destroyed
	if inst.Looped or not string.find(inst.Name, "_pooled") then
		inst:Destroy()
		return
	end

	-- Pooled: extract asset name from "AssetName_pooled"
	local name = string.match(inst.Name, "^(.+)_pooled$")
	if name then
		returnToPool(inst, name)
	else
		inst:Destroy()
	end
end

--[[ Rebuilds the asset cache and pre-warms pools.
     Call if SFX folder contents change at runtime. ]]
function Sound.RefreshCache()
	-- Destroy all pooled instances first
	for name, bucket in pool do
		for _, inst in bucket do
			inst:Destroy()
		end
		table.clear(bucket)
		allocCount[name] = 0
	end
	buildCache()
end

return Sound
