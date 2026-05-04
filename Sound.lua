-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Asset references
local SFX = script.Parent

-- Types
export type SoundOptions = {
	Volume:    number?, -- default: source volume
	PlaybackSpeed: number?, -- default: 1.0
	Looped:    boolean?, -- default: source setting
}

--------------------------------------------------------------------------------
-- Sound Module
--------------------------------------------------------------------------------
local Sound = {}

function Sound.PlaySound(soundName: string, parent: Instance?, options: SoundOptions?): Sound?
	local ResolvedParent: Instance = parent or workspace
	if not parent then
		warn(("[Sound] No parent supplied for '%s' — defaulting to workspace."):format(soundName))
	end

	local source = SFX:FindFirstChild(soundName)
	if not source then
		warn(("[Sound] Asset not found: '%s'"):format(soundName))
		return nil
	end

	local clone = source:Clone() :: Sound
	if options then
		if options.Volume        ~= nil then clone.Volume        = options.Volume        end
		if options.PlaybackSpeed ~= nil then clone.PlaybackSpeed = options.PlaybackSpeed end
		if options.Looped        ~= nil then clone.Looped        = options.Looped        end
		if options.Pitch         ~= nil then Instance.new("PitchShiftSoundEffect", clone).Octave = options.Pitch end
	end
	clone.Parent = ResolvedParent

	if not clone.Looped then
		local conn: RBXScriptConnection
		conn = clone.Ended:Connect(function()
			conn:Disconnect()
			clone:Destroy()
		end)
	end

	clone:Play()
	return clone
end

return Sound
