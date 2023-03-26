--[[
	Some codes referenced from
	CarWanna - https://steamcommunity.com/workshop/filedetails/?id=2801264901
	Vehicle Recycling - https://steamcommunity.com/sharedfiles/filedetails/?id=2289429759
	K15's Mods - https://steamcommunity.com/id/KI5/myworkshopfiles/?appid=108600
--]]

if isClient() and not isServer() then
	return
end
--[[
It seems impossible to get the real time coordinate of vehicles
Since vehicles ID are created on runtime and we store the SQL ID
It is impossible to obtain the vehicle ID despite having SQL ID, no method to do that
So ideally we get ID as it get loaded into the world but you can't get all the vehicle ID either because it only get loaded when people are at that place
So the best we could do is get last known location
We could override the vehicle part functions to include our coordinate update function
--]]

if not AVCS.oLowerCondition then
    AVCS.oLowerCondition = Vehicles.LowerCondition
end

function Vehicles.LowerCondition(vehicle, part, elapsedMinutes)
	AVCS.oLowerCondition(vehicle, part, elapsedMinutes)
	AVCS.updateVehicleCoordinate(vehicle)
end

--[[
The global modData is basically the database for this vehicle claiming mod
This global moddata is actively shared with the clients
The clients will do most of the checking which help keep the server light

There are two ModData which is storing it by Vehicle SQL ID or Player ID
I have both because I want to minimize looping to perform differnt things

ModData AVRByVehicleID is stored like this
<Vehicle SQL ID>
- <OwnerPlayerID>
- <ClaimDateTime>
- <CarModel>
- <LastLocationX>
- <LastLocationY>

ModData AVRByPlayerID is stored like this
<OwnerPlayerID>
- <Vehicle SQL ID 1>
- <Vehicle SQL ID 2>
and so on
--]]

function AVCS.claimVehicle(playerObj, vehicleID)
	local tempDB = ModData.get("AVCSByVehicleSQLID")
	local vehicleObj = getVehicleById(vehicleID.vehicle)

	-- Assign Object ModData, workaround for SQL ID not being consistent for client-side and server-side
	-- As such, we imprint the server-side SQL ID onto the vehicle parts at this point of time
	-- Oddly, vehicle itself cannot hold ModData
	local tempPart = AVCS.getMulePart(vehicleObj)
	if tempPart == false or tempPart == nil then return end
	if tempPart:getModData().SQLID == nil then
		tempPart:getModData().SQLID = vehicleObj:getSqlId()

		-- Force sync, users will get fresh mod data as they load into the cell
		-- But we want users who already in cell to get this data as well
		vehicleObj:transmitPartModData(tempPart)
	end

	-- Make sure is not already claimed
	-- Only SQL ID is persistent, vehicleID is created on runtime
	if tempDB[vehicleObj:getSqlId()] then
		-- Desync has occurred, force sync everyone
		--ModData.transmit("AVCSByVehicleSQLID")
		--ModData.transmit("AVCSByPlayerID")
	else
		tempDB[vehicleObj:getSqlId()] = {
			OwnerPlayerID = playerObj:getUsername(),
			ClaimDateTime = getTimestampMs(),
			CarModel = vehicleObj:getScript():getFullName(),
			LastLocationX = math.floor(vehicleObj:getX()),
			LastLocationY = math.floor(vehicleObj:getY())
		}
		
		-- Minimum data to send to clients
		local tempArr = {
			VehicleID = vehicleObj:getSqlId(),
			OwnerPlayerID = playerObj:getUsername(),
			ClaimDateTime = getTimestampMs(),
			CarModel = vehicleObj:getScript():getFullName(),
			LastLocationX = math.floor(vehicleObj:getX()),
			LastLocationY = math.floor(vehicleObj:getY())
		}
		
		-- Store the updated ModData --
		ModData.add("AVCSByVehicleSQLID", tempDB)
		
		tempDB = ModData.get("AVCSByPlayerID")
		if not tempDB[playerObj:getUsername()] then
			tempDB[playerObj:getUsername()] = {
				[vehicleObj:getSqlId()] = true
			}
		else
			tempDB[playerObj:getUsername()][vehicleObj:getSqlId()] = true
		end
		
		-- Store the updated ModData --
		ModData.add("AVCSByPlayerID", tempDB)
		
		--[[ Send the updated ModData to all clients
		ModData.transmit("AVCSByVehicleSQLID")
		ModData.transmit("AVCSByPlayerID")
		You could transmit the entire Global ModData but that can become bandwidth expensive
		So, we will send the bare minimum instead. We hope this won't be desynced
		Clients will always obtain be latest global ModData onConnected
		--]] 
		sendServerCommand("AVCS", "updateClaimVehicle", tempArr)
	end
end

function AVCS.unclaimVehicle(playerObj, vehicleID)
	local tempDB = ModData.get("AVCSByVehicleSQLID")
	local vehicleObj = getVehicleById(vehicleID.vehicle)
	
	if tempDB[vehicleObj:getSqlId()] then
		local ownerPlayerID = tempDB[vehicleObj:getSqlId()].OwnerPlayerID
		tempDB[vehicleObj:getSqlId()] = nil
		
		-- Store the updated ModData --
		ModData.add("AVCSByVehicleSQLID", tempDB)
		
		tempDB = ModData.get("AVCSByPlayerID")
		if tempDB[ownerPlayerID][vehicleObj:getSqlId()] then
			tempDB[ownerPlayerID][vehicleObj:getSqlId()] = nil
		end
		
		-- Store the updated ModData --
		ModData.add("AVCSByPlayerID", tempDB)
		
		local tempArr = {
			VehicleID = vehicleObj:getSqlId(),
			OwnerPlayerID = ownerPlayerID
		}
		
		--[[ Send the updated ModData to all clients
		ModData.transmit("AVCSByVehicleSQLID")
		ModData.transmit("AVCSByPlayerID")
		You could transmit the entire Global ModData but that can become bandwidth expensive
		So, we will send the bare minimum instead. We hope this won't be desynced
		Clients will always obtain be latest global ModData onConnected
		--]]
		
		sendServerCommand("AVCS", "updateUnclaimVehicle", tempArr)
	else
		-- Desync has occurred, force sync everyone
		--ModData.transmit("AVCSByVehicleSQLID")
		--ModData.transmit("AVCSByPlayerID")
	end
end

AVCS.onClientCommand = function(moduleName, command, playerObj, vehicleID)
	if moduleName == "AVCS" and command == "claimVehicle" then
		AVCS.claimVehicle(playerObj, vehicleID)
	elseif moduleName == "AVCS" and command == "unclaimVehicle" then
		if SandboxVars.AVCS.ServerSideCheckUnclaim then
			local checkResult = AVCS.checkPermission(playerObj, getVehicleById(vehicleID.vehicle))
			if type(checkResult) == "boolean" then
				if checkResult == false then
					return
				end
			elseif checkResult.permissions == false then
				return
			end
		end
		AVCS.unclaimVehicle(playerObj, vehicleID)
	end
end

local function OnServerStarted()
	-- When Mod first added to server
	if not ModData.exists("AVCSByVehicleSQLID") then ModData.create("AVCSByVehicleSQLID") end
	if not ModData.exists("AVCSByPlayerID") then ModData.create("AVCSByPlayerID") end
end

Events.OnServerStarted.Add(OnServerStarted)
Events.OnClientCommand.Add(AVCS.onClientCommand)