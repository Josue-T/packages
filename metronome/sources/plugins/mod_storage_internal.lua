-- * Metronome IM *
--
-- This file is part of the Metronome XMPP server and is released under the
-- ISC License, please see the LICENSE file in this source package for more
-- information about copyright and licensing.
--
-- As per the sublicensing clause, this file is also MIT/X11 Licensed.
-- ** Copyright (c) 2011-2012, Kim Alvefur, Matthew Wild, Waqas Hussain

local datamanager = require "core.storagemanager".olddm;

local host = module.host;

cache = {};

local driver = { name = "internal" };
local driver_mt = { __index = driver };

function driver:open(store)
	if not cache[store] then cache[store] = setmetatable({ store = store }, driver_mt); end
	return cache[store];
end
function driver:get(user)
	return datamanager.load(user, host, self.store);
end

function driver:set(user, data)
	return datamanager.store(user, host, self.store, data);
end

function driver:stores(username, type)
	return datamanager.stores(username, host, type);
end

function driver:purge(user)
	return datamanager.purge(user, host);
end

module:add_item("data-driver", driver);
