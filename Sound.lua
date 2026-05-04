-- Asset references
local SFX = script.Parent

--------------------------------------------------------------------------------
-- Configuration
--------------------------------------------------------------------------------
local DEBUG     = false  -- flip to true during development for warnings
local POOL_SIZE = 5      -- pre-warmed instances per unique sound asset
local POOL_MAX  = 16     -- hard ceiling per asset (prevents runaway growth)

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

--[[ Asset cache — built once at load, avoids repeated FindFirstChild.
     Key = sound name, Value = source Sound instance. ]]
local assetCache: { [string]: Sound } = {}

--[[ Original property snapshots for fast reset on pool return.
     Key = sound name, Value = { Volume, PlaybackSpeed, Looped } ]]
local defaults: { [string]: { Volume: number, PlaybackSpeed: number, Looped: boolean } } = {}

--[[ Object pool — per-asset LIFO stack of idle Sound instances. ]]
local pool: { [string]: { Sound } } = {}

--[[ Total allocated instances per asset (active + pooled) for POOL_MAX enforcement. ]]
local allocCount: { [string]: number } = {}

--[[ Reverse lookup — maps each active Sound instance back to its asset name
     and its pre-attached PitchShiftSoundEffect.
     Populated on acquire(), cleared on return.
     This replaces the fragile name-encoding approach and allows O(1) safe
     double-return detection and O(1) pitch-effect access. ]]
type PoolEntry = { name: string, fx: PitchShiftSoundEffect? }
local activeEntries: { [Sound]: PoolEntry } = {}

--------------------------------------------------------------------------------
-- Internal helpers
--------------------------------------------------------------------------------

--[[ Creates a single pooled Sound instance with a pre-attached, disabled
     PitchShiftSoundEffect. Never parents to workspace during construction. ]]
local function makePooledInstance(source: Sound, name: string): Sound
	local inst: Sound = source:Clone()
	inst.Name = name

	-- Set .Parent last (after all property writes) to minimise replication events.
	-- Properties are already copied from source via Clone, so no extra writes needed.
	local fx = Instance.new("PitchShiftSoundEffect")
	fx.Enabled = false
	-- Parent fx to inst before parenting inst to the world
	fx.Parent = inst
	-- Keep parked outside the world -- no spatial-audio processing cost
	-- (default after Clone is already nil, but explicit for clarity)
	inst.Parent = nil

	return inst
end

--[[ Builds the asset dictionary and pre-warms per-asset pools.
     Called once at module load. Safe to call again via RefreshCache(). ]]
local function buildCache()
	table.clear(assetCache)
	table.clear(defaults)

	for _, child in SFX:GetChildren() do
		if child:IsA("Sound") then
			local name: string = child.Name
			assetCache[name] = child
			defaults[name] = {
				Volume        = child.Volume,
				PlaybackSpeed = child.PlaybackSpeed,
				Looped        = child.Looped,
			}

			if not pool[name] then
				pool[name]       = {}   -- plain table; table.create(n) pre-fills nils which break table.insert indexing
				allocCount[name] = 0
			end

			for _ = 1, POOL_SIZE do
				table.insert(pool[name], makePooledInstance(child, name))
				allocCount[name] += 1
			end
		end
	end
end

buildCache()

--------------------------------------------------------------------------------
-- Pool internals
--------------------------------------------------------------------------------

--[[ Resets a pooled Sound to its source defaults.
     Skips property writes when the value is already correct.
     Uses the cached fx reference from activeEntries -- no child scan. ]]
local function resetSound(inst: Sound, name: string, fx: PitchShiftSoundEffect?)
	local def = defaults[name]
	if not def then return end

	if inst.Volume        ~= def.Volume        then inst.Volume        = def.Volume        end
	if inst.PlaybackSpeed ~= def.PlaybackSpeed then inst.PlaybackSpeed = def.PlaybackSpeed end
	if inst.Looped        ~= def.Looped        then inst.Looped        = def.Looped        end

	if fx and fx.Enabled then
		fx.Enabled = false
		fx.Octave  = 1
	end
end

--[[ Returns a pooled instance to the idle bucket.
     Idempotent: if the entry has already been cleared (double-return guard),
     this is a safe no-op. ]]
local function returnToPool(inst: Sound, entry: PoolEntry)
	-- Double-return guard: entry is removed from activeEntries on first return.
	-- If Ended fires after a manual StopSound, this will be nil and we bail out.
	if not activeEntries[inst] then return end
	activeEntries[inst] = nil

	local name = entry.name

	-- Destroyed-externally guard: IsDescendantOf(game) returns false for destroyed instances.
	if not inst:IsDescendantOf(game) then
		allocCount[name] = math.max(0, (allocCount[name] or 1) - 1)
		return
	end

	inst:Stop()
	inst.Parent = nil  -- un-parent: zero spatial processing cost while idle
	resetSound(inst, name, entry.fx)

	local bucket = pool[name]
	if bucket then
		table.insert(bucket, inst)
	end
end

--[[ Acquires a Sound instance from the pool, or allocates a new one if the
     pool is empty and POOL_MAX has not been reached.
     Registers the instance in activeEntries for O(1) reverse lookup.
     Returns nil only when the asset name is unknown. ]]
local function acquire(name: string): Sound?
	local source = assetCache[name]
	if not source then
		if DEBUG then
			warn(("[Sound] Asset not found: '%s'"):format(name))
		end
		return nil
	end

	local inst: Sound?

	-- Try pool first (LIFO pop -- most-recently-returned instance stays warmest)
	local bucket = pool[name]
	inst = bucket and table.remove(bucket) or nil

	if not inst then
		-- Pool empty -- allocate if under the ceiling
		local count = allocCount[name] or 0
		if count < POOL_MAX then
			inst = makePooledInstance(source, name)
			allocCount[name] = count + 1
		else
			if DEBUG then
				warn(("[Sound] Pool ceiling reached for '%s' (%d)"):format(name, POOL_MAX))
			end
			return nil
		end
	end

	-- Register in reverse-lookup with cached fx reference (avoids FindFirstChildWhichIsA at runtime)
	local fx = inst:FindFirstChildWhichIsA("PitchShiftSoundEffect") :: PitchShiftSoundEffect?
	activeEntries[inst] = { name = name, fx = fx }

	return inst
end

--------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------
local Sound = {}

--[[ Plays a sound by name.

     Non-looped sounds are drawn from the object pool and automatically
     returned when playback ends -- zero Clone / Destroy overhead on the hot path.

     Looped sounds are cloned (caller owns lifetime) and must be stopped /
     destroyed by the caller via Sound.StopSound().

     @param soundName  Name of a child Sound under the SFX folder.
     @param parent     Where to parent the Sound (defaults to workspace).
     @param options    Optional overrides for volume, speed, pitch, loop.
     @return           The Sound instance, or nil on failure. ]]
function Sound.PlaySound(soundName: string, parent: Instance?, options: SoundOptions?): Sound?
	local resolvedParent: Instance = parent or workspace

	if DEBUG and not parent then
		warn(("[Sound] No parent supplied for '%s' -- defaulting to workspace."):format(soundName))
	end

	local wantsLoop = options and options.Looped

	---------------------------------------------------------------------------
	-- Looped path -- clone (caller owns lifetime)
	---------------------------------------------------------------------------
	if wantsLoop then
		local source = assetCache[soundName]
		if not source then
			if DEBUG then
				warn(("[Sound] Asset not found: '%s'"):format(soundName))
			end
			return nil
		end

		local clone: Sound = source:Clone()
		clone.Looped = true
		if options then
			if options.Volume        ~= nil then clone.Volume        = options.Volume        end
			if options.PlaybackSpeed ~= nil then clone.PlaybackSpeed = options.PlaybackSpeed end
			if options.Pitch         ~= nil then
				-- Set .Parent last to avoid partial-state replication
				local fx = Instance.new("PitchShiftSoundEffect")
				fx.Octave  = options.Pitch
				fx.Parent  = clone
			end
		end
		clone.Parent = resolvedParent
		clone:Play()
		return clone
	end

	---------------------------------------------------------------------------
	-- Non-looped path -- pooled (zero-alloc hot path)
	---------------------------------------------------------------------------
	local inst = acquire(soundName)
	if not inst then return nil end

	-- Apply caller overrides before parenting (avoids mid-replication property writes)
	if options then
		if options.Volume        ~= nil then inst.Volume        = options.Volume        end
		if options.PlaybackSpeed ~= nil then inst.PlaybackSpeed = options.PlaybackSpeed end
		if options.Pitch         ~= nil then
			-- fx reference already cached in activeEntries -- no child scan
			local entry = activeEntries[inst]
			local fx    = entry and entry.fx
			if fx then
				fx.Octave  = options.Pitch
				fx.Enabled = true
			end
		end
	end

	inst.Parent = resolvedParent
	inst:Play()

	-- :Once() auto-disconnects after firing -- no stored connection, no leak.
	-- If StopSound() is called first, returnToPool clears activeEntries[inst],
	-- so the Ended callback becomes a safe no-op.
	local entry = activeEntries[inst]
	inst.Ended:Once(function()
		if entry then
			returnToPool(inst, entry)
		end
	end)

	return inst
end

--[[ Stops a sound immediately and returns pooled instances to the idle bucket.
     Safe to call on both pooled (non-looped) and cloned (looped) sounds.
     Uses the O(1) reverse-lookup table -- no name parsing, no child scans. ]]
function Sound.StopSound(inst: Sound?)
	if not inst then return end

	local entry = activeEntries[inst]
	if entry then
		-- Pooled instance -- return to pool (clears activeEntries[inst] internally)
		returnToPool(inst, entry)
	else
		-- Looped / untracked -- destroy directly
		inst:Destroy()
	end
end

--[[ Rebuilds the asset cache and re-warms pools.
     Call if the SFX folder contents change at runtime. ]]
function Sound.RefreshCache()
	-- Invalidate and destroy all idle pooled instances
	for name, bucket in pool do
		for _, inst in bucket do
			inst:Destroy()
		end
		table.clear(bucket)
		allocCount[name] = 0
	end
	-- Note: actively playing instances remain valid; they will return to
	-- the rebuilt pool via their Ended callbacks or StopSound() calls.
	buildCache()
end

return Sound
