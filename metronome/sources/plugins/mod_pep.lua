-- * Metronome IM *
--
-- This file is part of the Metronome XMPP server and is released under the
-- ISC License, please see the LICENSE file in this source package for more
-- information about copyright and licensing.

local hosts = hosts;
local core_post_stanza = metronome.core_post_stanza;
local ripairs, tonumber, type, os_remove, os_time, select = ripairs, tonumber, type, os.remove, os.time, select;

local pubsub = require "util.pubsub";
local st = require "util.stanza";
local jid_bare = require "util.jid".bare;
local jid_split = require "util.jid".split;
local uuid_generate = require "util.uuid".generate;
local is_contact_subscribed = require "core.rostermanager".is_contact_subscribed;
local calculate_hash = require "util.caps".calculate_hash;
local set_new = require "util.set".new;
local dataforms = require "util.dataforms";
local encode_node = datamanager.path_encode;
local get_path = datamanager.getpath;
local um_user_exists = usermanager.user_exists;

local xmlns_pubsub = "http://jabber.org/protocol/pubsub";
local xmlns_pubsub_errors = "http://jabber.org/protocol/pubsub#errors";
local xmlns_pubsub_event = "http://jabber.org/protocol/pubsub#event";
local xmlns_pubsub_owner = "http://jabber.org/protocol/pubsub#owner";

hash_map = {};
services = {};
local last_idle_cleanup = os_time();
local handlers = {};
local handlers_owner = {};
local NULL = {};

module:add_identity("pubsub", "pep", "Metronome");
module:add_feature("http://jabber.org/protocol/pubsub#access-presence");
module:add_feature("http://jabber.org/protocol/pubsub#auto-create");
module:add_feature("http://jabber.org/protocol/pubsub#create-and-configure");
module:add_feature("http://jabber.org/protocol/pubsub#create-nodes");
module:add_feature("http://jabber.org/protocol/pubsub#config-node");
module:add_feature("http://jabber.org/protocol/pubsub#delete-items");
module:add_feature("http://jabber.org/protocol/pubsub#delete-nodes");
module:add_feature("http://jabber.org/protocol/pubsub#filtered-notifications");
module:add_feature("http://jabber.org/protocol/pubsub#persistent-items");
module:add_feature("http://jabber.org/protocol/pubsub#publish");
module:add_feature("http://jabber.org/protocol/pubsub#purge-nodes");
module:add_feature("http://jabber.org/protocol/pubsub#retrieve-items");

-- Helpers.

local pep_errors = {
	["conflict"] = { "cancel", "conflict" };
	["invalid-jid"] = { "modify", "bad-request", nil, "invalid-jid" };
	["item-not-found"] = { "cancel", "item-not-found" };
	["feature-not-implemented"] = { "cancel", "feature-not-implemented" };
	["forbidden"] = { "cancel", "forbidden" };
	["not-subscribed"] = { "modify", "unexpected-request", nil, "not-subscribed" };
	["bad-request"] = { "cancel", "bad-request" };
};
function pep_error_reply(stanza, error)
	local e = pep_errors[error];
	local reply = st.error_reply(stanza, unpack(e, 1, 3));
	if e[4] then
		reply:tag(e[4], { xmlns = xmlns_pubsub_errors }):up();
	end
	return reply;
end

local singleton_nodes = set_new{ 
	"http://jabber.org/protocol/activity",
	"http://jabber.org/protocol/geoloc",
	"http://jabber.org/protocol/mood",
	"http://jabber.org/protocol/tune",
	"urn:xmpp:avatar:data",
	"urn:xmpp:avatar:metadata",
	"urn:xmpp:chatting:0",
	"urn:xmpp:browsing:0",
	"urn:xmpp:gaming:0",
	"urn:xmpp:viewing:0"
}
singleton_nodes:add_list(module:get_option("pep_custom_singleton_nodes"));

-- define in how many time (in seconds) inactive services should be deactivated
-- default is 3 days, minimal accepted is 3 hours.
local service_ttd = module:get_option_number("pep_deactivate_service_time", 259200)
if service_ttd < 10800 then service_ttd = 10800 end

local function idle_service_closer()
	for name, service in pairs(services) do
		if os_time() - service.last_used >= service_ttd then
			module:log("debug", "Deactivated inactive PEP Service -- %s", name);
			services[name] = nil;
		end
	end
end

-- define an item cache, useful to avoid event dupes
local cache_limit = module:get_option_number("pep_max_cached_items", 10);
if cache_limit > 30 then cache_limit = 30; end

local item_cache_mt = {};
item_cache_mt.__index = item_cache_mt;
function item_cache_mt:add(item, node, target, force)
	local _item = tostring(item);
	if force and self[target] and self[target][node] and self[target][node].item == _item then
		-- reset time for convenience...
		self[target][node].time = os_time();
		return true;
	elseif force and self[target] and self[target][node] and self[target][node].item ~= _item then
		-- pop old entry and reuse the table we already have
		self[target][node].item = _item;
		self[target][node].time = os_time();
		return true;
	end

	if not self:timeup(_item, node, target) then return false; end

	local _target_exists = self[target] and true;
	if self._count >= cache_limit and not _target_exists then
		-- pop an entry
		for entry in pairs(self) do 
			if entry ~= "_count" then self[entry] = nil; break; end
		end
		self._count = self._count - 1;
	end
	if not _target_exists then self._count = self._count + 1; end
	local _node_exists = self[target] and self[target][node] and true;
	self[target] = self[target] or { _count = 0 };
	if self[target]._count >= 10 and not _node_exists then
		for node in pairs(self[target]) do
			if node ~= "_count" then self[target][node] = nil; break; end
		end
		self[target]._count = self._count - 1;
	end
	if not _node_exists then self[target]._count = self[target]._count + 1; end
	self[target][node] = { item = _item, time = os_time() };

	return true;
end
function item_cache_mt:timeup(item, node, target)
	local _now = os_time();
	if not self[target] or not self[target][node] then return true; end
	if self[target][node] and 
	   (self[target][node].item ~= item or _now - self[target][node].time >= 5) then
		self[target][node] = nil;
		self[target]._count = self[target]._count - 1;
		return true;
	else
		return false;
	end
end

local function subscription_presence(user_bare, recipient)
	local recipient_bare = jid_bare(recipient);
	if (recipient_bare == user_bare) then return true end
	local username, host = jid_split(user_bare);
	return is_contact_subscribed(username, host, recipient_bare);
end

local function disco_info_query(user, from)
	-- COMPAT from ~= stanza.attr.to because OneTeam can"t deal with missing from attribute
	core_post_stanza(hosts[module.host], 
		st.stanza("iq", {from=user, to=from, id="disco", type="get"})
			:query("http://jabber.org/protocol/disco#info")
	);
	module:log("debug", "Sending disco info query to: %s", from);
end

local function get_caps_hash_from_presence(stanza)
	local t = stanza.attr.type;
	if not t then
		for _, child in pairs(stanza.tags) do
			if child.name == "c" and child.attr.xmlns == "http://jabber.org/protocol/caps" then
				local attr = child.attr;
				if attr.hash then -- new caps
					if attr.hash == "sha-1" and attr.node and attr.ver then return attr.ver, attr.node.."#"..attr.ver; end
				else -- legacy caps
					if attr.node and attr.ver then return attr.node.."#"..attr.ver.."#"..(attr.ext or ""), attr.node.."#"..attr.ver; end
				end
				return; -- bad caps format
			end
		end
	elseif t == "unavailable" or t == "error" then
		return;
	end
end

local function pep_broadcast_last(service, node, receiver)
	local ok, items, orderly = service:get_items(node, receiver, nil, 1);
	if items then
		for _, id in ipairs(orderly) do
			if service.item_cache:add(items[id], node, receiver) then 
				service:broadcaster(node, receiver, items[id]);
			end
		end
	end
end

local function pep_mutual_recs(source, target, interested)
	for jid, hash in pairs(source.recipients) do
		if jid_bare(jid) == source.name and type(hash) == "string" then
			interested[jid] = hash;
		end
	end
	for jid, hash in pairs(target.recipients) do
		if jid_bare(jid) == target.name and type(hash) == "string" then
			interested[jid] = hash;
		end
	end
end

local function pep_send(recipient, user, ignore)
	local rec_srv = services[jid_bare(recipient)];
	local user_srv = services[user];

	if ignore then -- fairly hacky...
		local nodes = user_srv.nodes;
		module:log("debug", "Ignoring notifications filtering for %s until we obtain 'em... if ever.", recipient);
		for node, object in pairs(nodes) do
			object.subscribers[recipient] = true;
			pep_broadcast_last(user_srv, node, recipient);
			object.subscribers[recipient] = nil;
		end		
	elseif not rec_srv then
		local nodes = user_srv.nodes;
		local rec_hash = user_srv.recipients[recipient];
		for node, object in pairs(nodes) do
			if hash_map[rec_hash] and hash_map[rec_hash][node] then
				object.subscribers[recipient] = true;
				pep_broadcast_last(user_srv, node, recipient);
			end
		end
	else
		local rec_nodes = rec_srv.nodes;
		local user_nodes = user_srv.nodes;
		local interested = {};
		pep_mutual_recs(user_srv, rec_srv, interested);

		-- Mutually subscribe
		for jid, hash in pairs(interested) do
			for node, obj in pairs(rec_nodes) do
				if hash_map[hash] and hash_map[hash][node] then obj.subscribers[jid] = true; end
			end
			for node, obj in pairs(user_nodes) do
				if hash_map[hash] and hash_map[hash][node] then obj.subscribers[jid] = true; end
			end			
		end

		for node in pairs(user_nodes) do
			pep_broadcast_last(user_srv, node, recipient);
		end
	end
end

local function pep_autosubscribe_recs(service, node)
	local recipients = service.recipients;
	local _node = service.nodes[node];
	if not _node then return; end

	for jid, hash in pairs(recipients) do
		if type(hash) == "string" and hash_map[hash] and hash_map[hash][node] then
			_node.subscribers[jid] = true;
		end
	end
end

local function probe_jid(user, from)
	core_post_stanza(hosts[module.host], st.presence({from=user, to=from, id="peptrigger", type="probe"}));
	module:log("debug", "Sending trigger probe to: %s", from);
end

function form_layout(service, name)
	local c_name = "Node configuration for "..name;
	local node = service.nodes[name];

	return dataforms.new({
		title = c_name,
		instructions = c_name,
		{
			name = "FORM_TYPE",
			type = "hidden",
			value = "http://jabber.org/protocol/pubsub#node_config"
		},
		{
			name = "pubsub#max_items",
			type = "text-single",
			label = "Max number of items to persist",
			value = type(node.config.max_items) == "number" and tostring(node.config.max_items) or "0"
		},
		{
			name = "pubsub#persist_items",
			type = "boolean",
			label = "Whether to persist items to storage or not",
			value = node.config.persist_items or false
		},
		{
			name = "pubsub#access_model",
			type = "list-single",
			label = "Access Model for the node, currently supported models are presence and open",
			value = {
				{ value = "presence", default = (node.config.access_model == "presence" or node.config.access_model == nil) and true },
				{ value = "open", default = node.config.access_model == "open" and true }
			}
		},
		{
			name = "pubsub#publish_model",
			type = "list-single",
			label = "Publisher Model for the node, currently supported models are publisher and open",
			value = {
				{ value = "publisher", default = (node.config.publish_model == "publisher" or node.config.publish_model == nil) and true },
				{ value = "open", default = node.config.publish_model == "open" and true }
			}
		},				
	});
end

function send_config_form(service, name, origin, stanza)
	return origin.send(st.reply(stanza)
		:tag("pubsub", { xmlns = "http://jabber.org/protocol/pubsub#owner" })
			:tag("configure", { node = name })
				:add_child(form_layout(service, name):form()):up()
	);
end

function process_config_form(service, name, form, new)
	local node_config, node;
	if new then
		node_config = {};
	else
		node = service.nodes[name];
		if not node then return false, "item-not-found"; end
		node_config = node.config;
	end

	if not form or form.attr.type ~= "submit" then return false, "bad-request" end

	for _, field in ipairs(form.tags) do
		if field.attr.var == "pubsub#max_items" then
			node_config.max_items = tonumber(field:get_child_text("value")) or 20;
		elseif field.attr.var == "pubsub#persist_items" and (field:get_child_text("value") == "0" or field:get_child_text("value") == "1") then
			node_config.persist_items = (field:get_child_text("value") == "0" and false) or (field:get_child_text("value") == "1" and true);
		elseif field.attr.var == "pubsub#access_model" then
			local value = field:get_child_text("value");
			if value == "presence" or value == "open" then node_config.access_model = value; end
		elseif field.attr.var == "pubsub#publish_model" then
			local value = field:get_child_text("value");
			if value == "publisher" or value == "open" then node_config.publish_model = value; end
		end
	end

	if new then return true, node_config end

	service:save_node(name);
	return true;
end

-- Module Definitions.

function handle_pubsub_iq(event)
	local origin, stanza = event.origin, event.stanza;
	local user = stanza.attr.to or (origin.username.."@"..origin.host);
	local full_jid = origin.full_jid;
	local username, host = jid_split(user);
	local time_now = os_time();
	local user_service = services[user];
	if not user_service and um_user_exists(username, host) then -- create service on demand.
		-- check if the creating user is the owner or someone requesting its pep service,
		-- required for certain crawling bots, e.g. Jappix Me
		if hosts[host].sessions[username] and (full_jid and jid_bare(full_jid) == username) then
			set_service(pubsub.new(pep_new(username)), user, true);

			-- discover the creating resource immediatly.
			module:fire_event("pep-get-client-filters", { user = user, to = full_jid });
		else
			set_service(pubsub.new(pep_new(username)), user, true);
		end
	end

	if not user_service then -- we should double check it's created,
		return;            -- it does not if the user doesn't exist.
	end

	user_service.last_used = time_now;

	if time_now - last_idle_cleanup >= 3600 then
		module:log("debug", "Checking for idle PEP Services...");
		idle_service_closer();
		last_idle_cleanup = time_now;
	end
	
	local pubsub = stanza.tags[1];
	local action = pubsub.tags[1];
	if not action then return origin.send(pep_error_reply(stanza, "bad-request")); end
	local handler = handlers[stanza.attr.type.."_"..action.name];
	local config = (pubsub.tags[2] and pubsub.tags[2].name == "configure") and pubsub.tags[2];
	local handler;

	if pubsub.attr.xmlns == xmlns_pubsub_owner then
		handler = handlers_owner[stanza.attr.type.."_"..action.name];
	else
		handler = handlers[stanza.attr.type.."_"..action.name];
	end	

	-- Update session to the one of the owner.
	if origin.username and origin.host and user_service.name == origin.username.."@"..origin.host then 
		user_service.session = origin;
	end

	if handler then
		if not config then 
			return handler(user_service, origin, stanza, action); 
		else 
			return handler(user_service, origin, stanza, action, config); 
		end
	else
		return origin.send(pep_error_reply(stanza, "feature-not-implemented"));
	end
end

-- pubsub ns handlers

function handlers.get_items(service, origin, stanza, items)
	local node = items.attr.node;
	local max = items and items.attr.max_items and tonumber(items.attr.max_items);
	local item = items:get_child("item");
	local id = item and item.attr.id;

	local ok, results, max_tosend = service:get_items(node, stanza.attr.from, id, max);
	if not ok then
		return origin.send(pep_error_reply(stanza, results));
	end
	
	local data = st.stanza("items", { node = node });
	if not max or max == 0 then
		for _, id in ripairs(max_tosend) do data:add_child(results[id]); end
	else
		for _, id in ipairs(max_tosend) do data:add_child(results[id]); end		
	end

	reply = st.reply(stanza)
		:tag("pubsub", { xmlns = xmlns_pubsub })
			:add_child(data);

	return origin.send(reply);
end

function handlers.set_create(service, origin, stanza, create, config)
	local node = create.attr.node;
	local ok, ret, reply;

	local node_config;
	if config then
		local form = config:get_child("x", "jabber:x:data");
		ok, node_config = process_config_form(service, node, form, true);
		if not ok then return origin.send(pep_error_reply(stanza, node_config)); end
	end

	if singleton_nodes:contains(node) and not node_config then
		node_config = { max_items = 1 };
	end

	if node then
		ok, ret = service:create(node, stanza.attr.from, node_config);
		if ok then
			reply = st.reply(stanza);
		else
			reply = pep_error_reply(stanza, ret);
		end
	else
		repeat
			node = uuid_generate();
			ok, ret = service:create(node, stanza.attr.from, node_config);
		until ok or ret ~= "conflict";
		if ok then
			reply = st.reply(stanza)
				:tag("pubsub", { xmlns = xmlns_pubsub })
					:tag("create", { node = node });
		else
			reply = pep_error_reply(stanza, ret);
		end
	end

	if ok then -- auto-resubscribe interested recipients
		pep_autosubscribe_recs(service, node);
	end
	return origin.send(reply);
end

function handlers.set_publish(service, origin, stanza, publish)
	local node = publish.attr.node;
	local from = stanza.attr.from or origin.full_jid;
	local item = publish:get_child("item");
	local recs = {};
	local recs_count = 0;
	local id = (item and item.attr.id) or uuid_generate();
	if item and not item.attr.id then item.attr.id = id; end
	if not service.nodes[node] then
	-- normally this would be handled just by publish() but we have to preceed its broadcast,
	-- so since autocreate on publish is in place, do create and then resubscribe interested items.
		local node_config;
		if singleton_nodes:contains(node) then node_config = { max_items = 1 }; end
		service:create(node, from, node_config);
		pep_autosubscribe_recs(service, node);
	end

	local ok, ret = service:publish(node, from, id, item);
	local reply;
	
	if ok then
		reply = st.reply(stanza)
			:tag("pubsub", { xmlns = xmlns_pubsub })
				:tag("publish", { node = node })
					:tag("item", { id = id });

		for target in pairs(service.nodes[node].subscribers) do
			service.item_cache:add(item, node, target, true);
		end		
	else
		reply = pep_error_reply(stanza, ret);
	end

	return origin.send(reply);
end

function handlers.set_retract(service, origin, stanza, retract)
	local node, notify = retract.attr.node, retract.attr.notify;
	notify = (notify == "1") or (notify == "true");
	local item = retract:get_child("item");
	local id = item and item.attr.id
	local reply, notifier;
	if notify then
		notifier = st.stanza("retract", { id = id });
	end
	local ok, ret = service:retract(node, stanza.attr.from, id, notifier);
	if ok then
		reply = st.reply(stanza);
	else
		reply = pep_error_reply(stanza, ret);
	end
	return origin.send(reply);
end

-- pubsub#owner ns handlers

function handlers_owner.get_configure(service, origin, stanza, action)
	local node = action.attr.node;
	if not node then
		return origin.send(pep_error_reply(stanza, "feature-not-implemented"));
	end

	if not service.nodes[node] then
		return origin.send(pep_error_reply(stanza, "item-not-found"));
	end

	local ret = service:get_affiliation(stanza.attr.from, node);

	if ret == "owner" then
		return send_config_form(service, node, origin, stanza);
	else
		return origin.send(pep_error_reply(stanza, "forbidden"));
	end
end

function handlers_owner.set_configure(service, origin, stanza, action)
	local node = action.attr.node;
	if not node then
		return origin.send(pep_error_reply(stanza, "feature-not-implemented"));
	end

	if not service.nodes[node] then
		return origin.send(pep_error_reply(stanza, "item-not-found"));
	end

	local ret = service:get_affiliation(stanza.attr.from, node)
	
	local reply;
	if ret == "owner" then
		local form = action:get_child("x", "jabber:x:data");
		if form and form.attr.type == "cancel" then
			return origin.send(st.reply(stanza));
		end

		local ok, ret = process_config_form(service, node, form);
		if ok then reply = st.reply(stanza); else reply = pep_error_reply(stanza, ret); end
	else
		reply = pep_error_reply(stanza, "forbidden");
	end
	return origin.send(reply);
end

function handlers_owner.set_delete(service, origin, stanza, delete)
	local node = delete.attr.node;
	local ok, ret, reply;
	if node then
		ok, ret = service:delete(node, stanza.attr.from);
		if ok then reply = st.reply(stanza); else reply = pep_error_reply(stanza, ret); end
	else
		reply = pep_error_reply(stanza, "bad-request");
	end
	return origin.send(reply);
end

function handlers_owner.set_purge(service, origin, stanza, purge)
	local node = purge.attr.node;
	local ok, ret, reply;
	if node then
		ok, ret = service:purge(node, stanza.attr.from);
		if ok then reply = st.reply(stanza); else reply = pep_error_reply(stanza, ret); end
	else
		reply = pep_error_reply(stanza, "bad-request");
	end
	return origin.send(reply);
end

-- handlers end

function broadcast(self, node, jids, item)
	local message;
	if type(item) == "string" and item == "deleted" then
		message = st.message({ from = self.name, type = "headline" })
			:tag("event", { xmlns = xmlns_pubsub_event })
				:tag("deleted", { node = node });
	elseif type(item) == "string" and item == "purged" then
		message = st.message({ from = self.name, type = "headline" })
			:tag("event", { xmlns = xmlns_pubsub_event })
				:tag("purged", { node = node });
	else
		message = st.message({ from = self.name, type = "headline" })
			:tag("event", { xmlns = xmlns_pubsub_event })
				:tag("items", { node = node });
		
		if item then
			item = st.clone(item);
			item.attr.xmlns = nil; -- Clear pubsub ns
			message:get_child("event", xmlns_pubsub_event):get_child("items"):add_child(item);
		end
	end

	local function send_event(jid)
		local function notify(s,f)
			module:log("debug", "%s -- service sending %s notification to %s", s, node, f);
			message.attr.to = f; core_post_stanza(self.session, message);
		end		
		
		local subscribers = self.nodes[node].subscribers;
		if subscribers[jid] then
			notify(self.name,jid);		
		end
	end

	if type(jids) == "table" then
		for jid in pairs(jids) do send_event(jid); end
	else send_event(jids); end
end

module:hook("iq/bare/http://jabber.org/protocol/pubsub:pubsub", handle_pubsub_iq);
module:hook("iq/bare/http://jabber.org/protocol/pubsub#owner:pubsub", handle_pubsub_iq);

local function append_disco_features(stanza)
	stanza:tag("identity", {category = "pubsub", type = "pep"}):up();
	stanza:tag("feature", {var = "http://jabber.org/protocol/pubsub#access-presence"}):up();
	stanza:tag("feature", {var = "http://jabber.org/protocol/pubsub#auto-create"}):up();
	stanza:tag("feature", {var = "http://jabber.org/protocol/pubsub#create-and-configure"}):up();
	stanza:tag("feature", {var = "http://jabber.org/protocol/pubsub#create-nodes"}):up();
	stanza:tag("feature", {var = "http://jabber.org/protocol/pubsub#delete-items"}):up();
	stanza:tag("feature", {var = "http://jabber.org/protocol/pubsub#delete-nodes"}):up();
	stanza:tag("feature", {var = "http://jabber.org/protocol/pubsub#filtered-notifications"}):up();
	stanza:tag("feature", {var = "http://jabber.org/protocol/pubsub#persistent-items"}):up();
	stanza:tag("feature", {var = "http://jabber.org/protocol/pubsub#publish"}):up();
	stanza:tag("feature", {var = "http://jabber.org/protocol/pubsub#purge-nodes"}):up();
	stanza:tag("feature", {var = "http://jabber.org/protocol/pubsub#retrieve-items"}):up();
end

module:hook("account-disco-info", function(event)
	local stanza = event.stanza;
	append_disco_features(stanza);
end);

module:hook("account-disco-items", function(event)
	local stanza = event.stanza;
	local bare = jid_bare(stanza.attr.to);
	local user_data = services[bare].nodes;

	if user_data then
		for node, _ in pairs(user_data) do
			stanza:tag("item", {jid = bare, node = node}):up();
		end
	end
end);

module:hook("presence/bare", function(event)
	-- inbound presence to bare JID recieved           
	local origin, stanza = event.origin, event.stanza;
	local user = stanza.attr.to or (origin.username.."@"..origin.host);
	local t = stanza.attr.type;
	local self = not stanza.attr.to;
	local service = services[user];
	
	if not service then return nil; end -- User Service doesn't exist
	local nodes = service.nodes;
	local recipients = service.recipients;
	
	if not t then -- available presence
		if self or subscription_presence(user, stanza.attr.from) then
			local recipient = stanza.attr.from;
			local current = recipients and recipients[recipient];
			local hash = get_caps_hash_from_presence(stanza);
			if not hash then
				if current then	
					hash = current;
				else
					-- We shall drop sending disco infos to all clients which don't include caps
					-- in their presence, it's not perfect, but it's the only way to get optimal
					-- non-volatile states.
					current = false;
					recipients[recipient] = false;
				end
			else
				recipients[recipient] = hash;
			end
				
			if not hash_map[hash] then
				if current ~= false then
					module:fire_event("pep-get-client-filters", 
					{ user = user; to = stanza.attr.from or origin.full_jid,
					  recipients = recipients });
				
					-- ignore filters once either because they aren't supported or because we don't have 'em yet
					pep_send(recipient, user, true);
				end
			else
				recipients[recipient] = hash;
				pep_send(recipient, user);
			end
		end
	elseif t == "unavailable" then
		local from = stanza.attr.from;
		local client_map = hash_map[recipients[from]];
		for name in pairs(client_map or NULL) do
			if nodes[name] then nodes[name].subscribers[from] = nil; end
		end
		recipients[from] = nil;
	elseif not self and t == "unsubscribe" then
		local from = jid_bare(stanza.attr.from);
		local subscriptions = recipients;
		if subscriptions then
			for subscriber in pairs(subscriptions) do
				if jid_bare(subscriber) == from then
					local client_map = hash_map[recipients[subscriber]];
					for name in pairs(client_map or NULL) do
						if nodes[name] then nodes[name].subscribers[subscriber] = nil; end
					end
					recipients[subscriber] = nil;
				end
			end
		end
	end
end, 10);

module:hook("pep-get-client-filters", function(event)
	local user, to, recipients = event.user, event.to, event.hash, event.recipients;
	disco_info_query(user, to);
end, 100);

module:hook("iq-result/bare/disco", function(event)
	local session, stanza = event.origin, event.stanza;
	if stanza.attr.type == "result" then
		local disco = stanza.tags[1];
		if disco and disco.name == "query" and disco.attr.xmlns == "http://jabber.org/protocol/disco#info" then
			-- Process disco response
			local self = not stanza.attr.to;
			local user = stanza.attr.to or (session.username.."@"..session.host);
			local service = services[user];
			if not service then return true; end -- User's pep service doesn't exist
			local nodes = service.nodes;
			local recipients = service.recipients;
			local contact = stanza.attr.from;
			local current = recipients[contact];
			if not current then return true; end

			module:log("debug", "Processing disco response from %s", stanza.attr.from);
			local ver = current;
			if not string.find(current, "#") then
				ver = calculate_hash(disco.tags); -- calculate hash
			end
			local notify = {};
			local has_notify = false;
			for _, feature in pairs(disco.tags) do
				if feature.name == "feature" and feature.attr.var then
					local nfeature = feature.attr.var:match("^(.*)%+notify$");
					if nfeature then notify[nfeature] = true; has_notify = true; end
				end
			end
			if not has_notify then 
				hash_map[ver] = notify;
				recipients[contact] = false;
				return true;
			end
			hash_map[ver] = notify; -- update hash map
			recipients[contact] = ver; -- and contact hash
			if self then
				module:log("debug", "Discovering interested roster contacts...");
				for jid, item in pairs(session.roster) do -- for all interested contacts
					if item.subscription == "both" or item.subscription == "from" then
						local node, host = jid_split(jid);
						if hosts[host] and hosts[host].sessions and hosts[host].sessions[node] then
							-- service discovery local users' av. resources
							for resource in pairs(hosts[host].sessions[node].sessions) do
								disco_info_query(user, jid .. "/" .. resource);
							end
						else
							-- send a probe trigger
							probe_jid(user, jid);
						end
					end
				end
			end
			for node, object in pairs(nodes) do
				pep_send(contact, user);
			end
			return true; -- end cb processing.
		end
	end
end, -1);

module:hook_global("user-deleted", function(event)
	local username, host = event.username, event.host;

	if host == module.host then
		local jid = username.."@"..host;
		local encoded_node = encode_node(username);
		local service = services[jid] or set_service(pubsub.new(pep_new(username)), jid, true);
		local nodes = service.nodes;
		local store = service.config.store;

		for node in pairs(nodes) do
			module:log("debug", "Wiped %s's node %s", jid, node);
			store:set(node, nil); 
		end
		store:set(nil, nil);
		services[jid] = nil;

		local type = select(2, storagemanager.get_driver(host));
		if type == "internal" then
			local path = get_path(encoded_node, host, "pep"):match("^(.*)%.");
			local done = os_remove(path);

			if done then
				module:log("debug", "Removed %s pep store directory (%s)", jid, path);
			end
		end
	end	
end, 100);

local admin_aff = "owner";
local function get_affiliation(self, jid, node)
	local bare_jid = jid_bare(jid);
	if bare_jid == self.name then
		return admin_aff;
	else
		local node = self.nodes[node];
		local access_model = node.config.access_model;
		if node and (not access_model or access_model == "presence") then
			local user, host = jid_split(self.name);
			if not is_contact_subscribed(user, host, bare_jid) then	return "no_access"; end
		end
			
		return "none";
	end
end

function set_service(new_service, jid, restore)
	services[jid] = new_service;
	services[jid].item_cache = { _count = 0 };
	setmetatable(services[jid].item_cache, item_cache_mt);
	services[jid].last_used = os_time();
	services[jid].name = jid;
	services[jid].recipients = {};
	module.environment.services[jid] = services[jid];
	if restore then 
		services[jid]:restore(); 
		for name, node in pairs(services[jid].nodes) do 
			node.subscribers = {};
			services[jid]:save_node(name);
		end
	end
	return services[jid];
end

function pep_new(node)
	local encoded_node = encode_node(node);

	local new_service = {
			capabilities = {
				no_access = {
					create = false;
					delete = false;
					publish = false;
					purge = false;
					retract = false;
					get_nodes = false;

					subscribe = false;
					unsubscribe = false;
					get_subscription = false;
					get_subscriptions = false;
					get_items = false;

					subscribe_other = false;
					unsubscribe_other = false;
					get_subscription_other = false;
					get_subscriptions_other = false;

					be_subscribed = false;
					be_unsubscribed = false;

					set_affiliation = false;

					dummy = true;
				};
				none = {
					create = false;
					delete = false;
					publish = false;
					purge = false;
					retract = false;
					get_nodes = true;

					subscribe = false;
					unsubscribe = true;
					get_subscription = true;
					get_subscriptions = true;
					get_items = true;

					subscribe_other = false;
					unsubscribe_other = false;
					get_subscription_other = false;
					get_subscriptions_other = false;

					be_subscribed = true;
					be_unsubscribed = true;

					set_affiliation = false;
				};
				publisher = {
					create = false;
					delete = false;
					publish = true;
					purge = false;
					retract = true;
					get_nodes = true;

					subscribe = true;
					unsubscribe = true;
					get_subscription = true;
					get_subscriptions = true;
					get_items = true;

					subscribe_other = false;
					unsubscribe_other = false;
					get_subscription_other = false;
					get_subscriptions_other = false;

					be_subscribed = true;
					be_unsubscribed = true;

					set_affiliation = false;
				};
				owner = {
					create = true;
					delete = true;
					publish = true;
					purge = true;
					retract = true;
					get_nodes = true;

					subscribe = true;
					unsubscribe = true;
					get_subscription = true;
					get_subscriptions = true;
					get_items = true;

					subscribe_other = true;
					unsubscribe_other = true;
					get_subscription_other = true;
					get_subscriptions_other = true;

					be_subscribed = true;
					be_unsubscribed = true;

					set_affiliation = true;
				};
			};

			node_default_config = {
				max_items = 20;
			};

			autocreate_on_publish = true;
			autocreate_on_subscribe = true;

			broadcaster = broadcast;
			get_affiliation = get_affiliation;

			normalize_jid = jid_bare;

			store = storagemanager.open(module.host, "pep/"..encoded_node);
		};

	return new_service;
end

function module.save()
	return { hash_map = hash_map, services = services, last_idle_cleanup = last_idle_cleanup };
end

function module.restore(data)
	local time_now = os_time();

	hash_map = data.hash_map or {};
	last_idle_cleanup = data.last_idle_cleanup or time_now;
	local _services = data.services or {};
	for id, service in pairs(_services) do
		username = jid_split(id);
		services[id] = set_service(pubsub.new(pep_new(username)), id);
		services[id].item_cache = service.item_cache or { _count = 0 };
		setmetatable(services[id].item_cache, item_cache_mt);
		services[id].last_used = service.last_used or time_now;
		services[id].nodes = service.nodes or {};
		services[id].recipients = service.recipients or {};
	end
end
