storage = minetest.get_mod_storage()
entities_by_id = {}
local highest_id = storage:get_int("highest_id")

-- x/z-rotation
local function horizontal_rotation(d)
    return math.atan2(d.y, math.sqrt(d.x*d.x + d.z*d.z))
end

-- y-rotation
local function vertical_rotation(d)
    return -math.atan2(d.x, d.z)
end

-- gets rotation in radians for a z-facing object
function get_rotation(direction)
    return {
        x = horizontal_rotation(direction),
        y = vertical_rotation(direction),
        z = 0
    }
end

-- converts a rotation from -pi to pi to 2pi to 0
function convert_rotation(rotation)
    return vector.apply(rotation, function(c)
        if c < 0 then
            return 2*math.pi + c
        end
        return c
    end)
end

-- shorthand
function get_converted_rotation(direction)
    return convert_rotation(get_rotation(direction))
end

-- normalizes a rotation
function normalize_rotation(rotation)
    return vector.apply(rotation, function(c)
        local nc = c % (2*math.pi)
        if c < 0 then
            return 2*math.pi + nc
        end
        return nc
    end)
end

function get_minimum_converted_rotation_difference(rotation, other_rotation)
    return vector.apply(vector.subtract(rotation, other_rotation), function(c)
        if c > math.pi then
            return -2*math.pi + c
        end
        if c < -math.pi then
            return 2*math.pi + c
        end
        return c
    end)
end

-- gets rotation in radians for a wielditem (such as a sword)
function get_wield_rotation(direction)
    return {
        x = 0,
        y = 1.5*math.pi+vertical_rotation(direction),
        z = 1.25*math.pi+horizontal_rotation(direction)
    }
end

-- gets the direction for a rotated vector (0, 0, 1), inverse of get_rotation
function get_direction(rotation)
    local rx, ry = rotation.x, rotation.y
    local direction = {}
    -- x rotation
    direction.y = math.sin(rx)
    local z = math.cos(rx)
    -- y rotation
    direction.x = -(z * math.sin(ry))
    direction.z = z * math.cos(ry)
    return direction
end

-- TODO implement physics such as air resistance
local engine_moveresult = minetest.has_feature("object_step_has_moveresult")
local sensitivity = 0.01
function register_entity(name, def)
    local props = def.lua_properties
    def.lua_properties = nil
    local on_activate = def.on_activate or function() end
    local on_step = def.on_step or function() end
    local terminal_speed = props.terminal_speed
    if terminal_speed then
        local old_on_step = on_step
        function on_step(self, dtime, ...)
            old_on_step(self, dtime, ...)
            local obj = self.object
            local vel = obj:get_velocity()
            if not vel then return end -- object has been deleted
            local len = vector.length(obj:get_velocity())
            if len > terminal_speed then
                obj:set_velocity(vector.multiply(vector.divide(vel, len)))
            end
        end
    end
    if props.moveresult then
        -- localizing variables for performance reasons
        local mr = props.moveresult
        local mr_collisions = mr.collisions
        local mr_axes = mr.axes
        local mr_old_velocity = mr.old_velocity
        local mr_acc_dependent = mr.acceleration_dependent
        if engine_moveresult and not mr_acc_dependent then
            local old_on_step = on_step
            function on_step(self, dtime, moveresult)
                if moveresult.collides then
                    if mr_axes then
                        local axes = {}
                        for _, collision in ipairs(moveresult.collisions) do
                            axes[collision.axis] = true
                        end
                        moveresult.axes = axes
                    end
                    if mr_old_velocity then
                        moveresult.old_velocity = moveresult.collisions[1].old_velocity
                    end
                end
                old_on_step(self, dtime, moveresult)
            end
        else
            local old_on_activate = on_activate
            function on_activate(self, staticdata, dtime)
                old_on_activate(self, staticdata, dtime)
                self._last_velocity = self.object:get_velocity()
            end
            local old_on_step = on_step
            function on_step(self, dtime)
                local obj = self.object
                local moveresult = {collides = false}
                if self._last_velocity then
                    local expected_vel = vector.add(self._last_velocity, vector.multiply(obj:get_acceleration(), dtime))
                    local velocity = obj:get_velocity()
                    local diff = vector.subtract(expected_vel, velocity)
                    local collides = vector.length(diff) >= sensitivity
                    moveresult.collides = collides
                    if collides then
                        if mr_collisions then
                            local collisions = {}
                            diff = vector.apply(diff, math.abs)
                            local new_velocity = self._last_velocity
                            for axis, component_diff in pairs(diff) do
                                if component_diff > sensitivity then
                                    new_velocity[axis] = velocity[axis]
                                    table.insert(collisions, {
                                        axis = axis,
                                        old_velocity = self._last_velocity,
                                        new_velocity = new_velocity
                                    })
                                end
                            end
                            moveresult.collisions = collisions
                        end
                        if mr_axes then
                            local axes = {}
                            diff = vector.apply(diff, math.abs)
                            for axis, component_diff in pairs(diff) do
                                if component_diff > sensitivity then
                                    axes[axis] = true
                                end
                            end
                            moveresult.axes = axes
                        end
                        if mr_old_velocity then
                            moveresult.old_velocity = self._last_velocity
                        end
                        if mr_acc_dependent then
                            moveresult.acceleration_dependent = vector.length(vector.subtract(self._last_velocity, velocity)) < sensitivity
                        end
                    end
                end
                old_on_step(self, dtime, moveresult)
                self._last_velocity = obj:get_velocity()
            end
            function def._set_velocity(self, velocity)
                self.object:set_velocity(velocity)
                self._last_velocity = velocity
            end
        end
    end
    local props_staticdata = props.staticdata
    if props_staticdata then
        local implementation
        if type(props_staticdata) == "table" then
            implementation = props_staticdata
        else
            implementation = ({
                json = {
                    serializer = minetest.write_json,
                    deserializer = minetest.parse_json
                },
                lua = {
                    serializer = minetest.serialize,
                    deserializer = minetest.deserialize
                }
            })[props_staticdata]
        end
        local serializer = implementation.serializer
        local deserializer = implementation.deserializer
        local old_on_activate = on_activate
        function on_activate(self, staticdata, dtime)
            self._ = (staticdata ~= "" and deserializer(staticdata)) or {}
            old_on_activate(self, staticdata, dtime)
        end
        function def.get_staticdata(self)
            return serializer(self._)
        end
    end
    if props.id then
        assert(props_staticdata)
        local old_on_activate = on_activate
        function on_activate(self, staticdata, dtime)
            old_on_activate(self, staticdata, dtime)
            if not self._.id then
                highest_id = highest_id + 1
                self._.id = highest_id
                storage:set_int("highest_id", highest_id)
            end
            entities_by_id[self._.id] = self
        end
    end
    def.on_activate = on_activate
    def.on_step = on_step
    minetest.register_entity(name, def)
end