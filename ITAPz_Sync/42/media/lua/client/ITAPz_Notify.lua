--[[ ITAPz — notifiche private in gioco (client).

     Il server manda sendServerCommand(player, "ITAPz_Sync", "Notify", {message}).
     Qui la notifica viene mostrata solo a chi la riceve, nella chat di sinistra:
     nessun altro giocatore la vede.

     addChatLine e' un global del gioco (Java): se per qualche motivo non ci
     fosse, si ripiega sul fumetto sopra il personaggio. ]]

local function onServerCommand(module, command, args)
    if module ~= "ITAPz_Sync" or command ~= "Notify" then return end
    if not args or not args.message then return end

    local testo = tostring(args.message)
    local ok = pcall(function() addChatLine(testo, 0.83, 0.68, 0.21) end)
    if not ok then
        local p = getSpecificPlayer(0)
        if p then pcall(function() p:Say(testo) end) end
    end
end

Events.OnServerCommand.Add(onServerCommand)
