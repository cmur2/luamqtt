-- busted -e 'package.path="./?/init.lua;"..package.path;' spec/*.lua
-- DOC: http://docs.oasis-open.org/mqtt/mqtt/v3.1.1/errata01/os/mqtt-v3.1.1-errata01-os-complete.html

describe("MQTT v3.1.1 protocol: parsing packets", function()
	local protocol = require("mqtt.protocol")
	local protocol4 = require("mqtt.protocol4")

	it("protocol.parse_var_length", function()
		-- returns read_func-compatible function
		local function make_read_func(data)
			local i = 0
			return function(_)
				i = i + 1
				if i <= #data then
					return string.char(data[i])
				else
					return false, "no more data available"
				end
			end
		end

		assert.is_false(protocol.parse_var_length(make_read_func{}))

		-- DOC: Table 2.4 Size of Remaining Length field
		assert.are.equal(0, protocol.parse_var_length(make_read_func{0x00}))
		assert.are.equal(1, protocol.parse_var_length(make_read_func{0x01}))
		assert.are.equal(127, protocol.parse_var_length(make_read_func{0x7F}))
		assert.are.equal(128, protocol.parse_var_length(make_read_func{0x80, 0x01}))
		assert.are.equal(16383, protocol.parse_var_length(make_read_func{0xFF, 0x7F}))
		assert.are.equal(16384, protocol.parse_var_length(make_read_func{0x80, 0x80, 0x01}))
		assert.are.equal(2097151, protocol.parse_var_length(make_read_func{0xFF, 0xFF, 0x7F}))
		assert.are.equal(2097152, protocol.parse_var_length(make_read_func{0x80, 0x80, 0x80, 0x01}))
		assert.are.equal(268435455, protocol.parse_var_length(make_read_func{0xFF, 0xFF, 0xFF, 0x7F}))

		assert.is_false(protocol.parse_var_length(make_read_func{0xFF, 0xFF, 0xFF, 0x7F + 1}))
		assert.is_false(protocol.parse_var_length(make_read_func{0xFF, 0xFF, 0xFF, 0xFF}))
	end)

	-- returns read_func-compatible function
	local function make_read_func_hex(hex)
		-- decode hex string into data
		local data = {}
		for i = 1, hex:len() / 2 do
			local byte = hex:sub(i*2 - 1, i*2)
			data[#data + 1] = string.char(tonumber(byte, 16))
		end
		data = table.concat(data)
		-- and return read_func
		local data_size = data:len()
		local pos = 1
		return function(size)
			if pos > data_size then
				return false, "no more data available"
			end
			local res = data:sub(pos, pos + size - 1)
			if res:len() ~= size then
				return false, "not enough unparsed data"
			end
			pos = pos + size
			return res
		end
	end

	it("failures", function()
		assert.is_false(protocol4.parse_packet(make_read_func_hex("")))
		assert.is_false(protocol4.parse_packet(make_read_func_hex("01")))
		assert.is_false(protocol4.parse_packet(make_read_func_hex("02")))
		assert.is_false(protocol4.parse_packet(make_read_func_hex("0304")))
		assert.is_false(protocol4.parse_packet(make_read_func_hex("20")))
		assert.is_false(protocol4.parse_packet(make_read_func_hex("20030000"))) -- CONNACK with invalid length
	end)

	it("CONNACK", function()
		assert.is_false(protocol4.parse_packet(make_read_func_hex("")))
		--[[
			20 					packet type == 2 (CONNACK), flags == 0
			02 					variable length == 2 bytes
				00 				0-th bit is sp (session present) -- DOC: 3.2.2.2 Session Present
				00 				CONNACK return code
		]]
		assert.are.same(
			{
				type=protocol.packet_type.CONNACK, sp=false, rc=0
			},
			protocol4.parse_packet(make_read_func_hex(
				"20020000"
			))
		)
		assert.are.same(
			{
				type=protocol.packet_type.CONNACK, sp=true, rc=0
			},
			protocol4.parse_packet(make_read_func_hex(
				"20020100"
			))
		)
		assert.are.same(
			{
				type=protocol.packet_type.CONNACK, sp=false, rc=1
			},
			protocol4.parse_packet(make_read_func_hex(
				"20020001"
			))
		)
	end)

	it("PUBLISH", function()
		--[[
			3B 					packet type == 3 (PUBLISH), flags == 0xB == 1011 (dup=true, qos=1, retain=true)
			15 					variable length == 0x15 == 21 bytes
				0004 736F6D65 		topic "some"
				0001 				packet id of PUBLISH packet
					716F73203D3D20312C206F6B21 		payload to publish: "qos == 1, ok!"
		]]
		assert.are.same(
			{
				type = protocol.packet_type.PUBLISH,
				dup = true,
				qos = 1,
				retain = true,
				packet_id = 1,
				topic = "some",
				payload = "qos == 1, ok!",
			},
			protocol4.parse_packet(make_read_func_hex(
				"3B150004736F6D650001716F73203D3D20312C206F6B21"
			))
		)
		--[[
			30 					packet type == 3 (PUBLISH), flags == 0 == 0000 (dup=false, qos=0, retain=false)
			13 					variable length == 0x13 == 19 bytes
				0004 736F6D65 		topic "some"
					716F73203D3D20312C206F6B21 		payload to publish: "qos == 1, ok!"
		]]
		assert.are.same(
			{
				type = protocol.packet_type.PUBLISH,
				dup = false,
				qos = 0,
				retain = false,
				topic = "some",
				payload = "qos == 1, ok!",
			},
			protocol4.parse_packet(make_read_func_hex(
				"30130004736F6D65716F73203D3D20312C206F6B21"
			))
		)
	end)

	it("PUBACK", function()
		--[[
			40 					packet type == 4 (PUBACK), flags == 0
			02 					variable length == 2 bytes
				0001 			packet id of acknowledged PUBLISH packet
		]]
		assert.are.same(
			{
				type=protocol.packet_type.PUBACK, packet_id=1
			},
			protocol4.parse_packet(make_read_func_hex(
				"40020001"
			))
		)
		--[[
			40 					packet type == 4 (PUBACK), flags == 0
			02 					variable length == 2 bytes
				7FF7 			packet id of acknowledged PUBLISH packet
		]]
		assert.are.same(
			{
				type=protocol.packet_type.PUBACK, packet_id=0x7FF7
			},
			protocol4.parse_packet(make_read_func_hex(
				"40027FF7"
			))
		)
	end)

	it("PUBREC", function()
		--[[
			50 					packet type == 5 (PUBREC), flags == 0
			02 					variable length == 2 bytes
				0001 			packet id of acknowledged PUBLISH packet
		]]
		assert.are.same(
			{
				type=protocol.packet_type.PUBREC, packet_id=1
			},
			protocol4.parse_packet(make_read_func_hex(
				"50020001"
			))
		)
		--[[
			50 					packet type == 5 (PUBREC), flags == 0
			02 					variable length == 2 bytes
				4567 			packet id of acknowledged PUBLISH packet
		]]
		assert.are.same(
			{
				type=protocol.packet_type.PUBREC, packet_id=0x4567
			},
			protocol4.parse_packet(make_read_func_hex(
				"50024567"
			))
		)
	end)

	it("PUBREL", function()
		--[[
			62 					packet type == 6 (PUBREL), flags == 2  (reserved bits: 0010)
			02 					variable length == 2 bytes
				0001 			packet id of acknowledged PUBLISH packet
		]]
		assert.are.same(
			{
				type=protocol.packet_type.PUBREL, packet_id=1
			},
			protocol4.parse_packet(make_read_func_hex(
				"62020001"
			))
		)
		--[[
			62 					packet type == 6 (PUBREL), flags == 2 (reserved bits: 0010)
			02 					variable length == 2 bytes
				1234 			packet id of acknowledged PUBLISH packet
		]]
		assert.are.same(
			{
				type=protocol.packet_type.PUBREL, packet_id=0x1234
			},
			protocol4.parse_packet(make_read_func_hex(
				"62021234"
			))
		)
	end)

	it("SUBACK", function()
		--[[
			90 					packet type == 9 (SUBACK), flags == 0
			03 					variable length == 3 bytes
				0001 			packet id of acknowledged SUBSCRIBE packet
					00 			payload: return code, maximum allowed QoS
		]]
		assert.are.same(
			{
				type=protocol.packet_type.SUBACK, packet_id=1, rc=0, failure=false,
			},
			protocol4.parse_packet(make_read_func_hex(
				"9003000100"
			))
		)
		--[[
			90 					packet type == 9 (SUBACK), flags == 0
			03 					variable length == 3 bytes
				1234 			packet id of acknowledged SUBSCRIBE packet
					00 			payload: return code, maximum allowed QoS
		]]
		assert.are.same(
			{
				type=protocol.packet_type.SUBACK, packet_id=0x1234, rc=0, failure=false,
			},
			protocol4.parse_packet(make_read_func_hex(
				"9003123400"
			))
		)
	end)

	it("UNSUBACK", function()
		--[[
			B0 					packet type == 0xB == 11 (UNSUBACK), flags == 0
			02 					variable length == 2 bytes
				0001 			packet id of acknowledged UNSUBSCRIBE packet
		]]
		assert.are.same(
			{
				type=protocol.packet_type.UNSUBACK, packet_id=1,
			},
			protocol4.parse_packet(make_read_func_hex(
				"B0020001"
			))
		)
		--[[
			B0 					packet type == 0xB == 11 (UNSUBACK), flags == 0
			02 					variable length == 2 bytes
				1234 			packet id of acknowledged UNSUBSCRIBE packet
		]]
		assert.are.same(
			{
				type=protocol.packet_type.UNSUBACK, packet_id=0x1234,
			},
			protocol4.parse_packet(make_read_func_hex(
				"B0021234"
			))
		)
	end)

	it("PINGRESP", function()
		--[[
			D0 					packet type == 0xD == 13 (PINGRESP), flags == 0
			00 					variable length == 0 bytes
		]]
		assert.are.same(
			{
				type=protocol.packet_type.PINGRESP,
			},
			protocol4.parse_packet(make_read_func_hex(
				"D000"
			))
		)
	end)
end)

-- vim: ts=4 sts=4 sw=4 noet ft=lua
