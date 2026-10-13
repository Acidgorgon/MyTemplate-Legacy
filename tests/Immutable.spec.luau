local Immutable = require("../src/shared/Data/Immutable")

return function(t)
	t.test("DeepCopy makes independent unfrozen tables", function()
		local source = table.freeze({ a = table.freeze({ 1, 2 }) })
		local copy = Immutable.DeepCopy(source)
		t.falsy(table.isfrozen(copy))
		t.falsy(table.isfrozen(copy.a))
		copy.a[1] = 9
		t.equal(source.a[1], 1)
	end)

	t.test("DeepFreeze freezes nested tables", function()
		local value = Immutable.DeepFreeze({ a = { b = {} } })
		t.truthy(table.isfrozen(value))
		t.truthy(table.isfrozen(value.a.b))
	end)

	t.test("Share returns old when nothing changed", function()
		local old = Immutable.DeepFreeze({ a = { 1, 2 }, b = { c = 1 } })
		local draft = Immutable.DeepCopy(old)
		t.equal(Immutable.Share(old, draft), old)
	end)

	t.test("Share keeps unchanged subtables and freezes the result", function()
		local old = Immutable.DeepFreeze({ a = { 1, 2 }, b = { c = 1 }, n = 1 })
		local draft = Immutable.DeepCopy(old)
		draft.b.c = 2
		local new = Immutable.Share(old, draft)
		t.truthy(new ~= old)
		t.equal(new.a, old.a, "unchanged subtable reused")
		t.truthy(new.b ~= old.b)
		t.equal(new.b.c, 2)
		t.truthy(table.isfrozen(new) and table.isfrozen(new.b))
	end)

	t.test("Share notices removed keys and table.insert", function()
		local old = Immutable.DeepFreeze({ list = { "x" }, gone = 1 })
		local draft = Immutable.DeepCopy(old)
		draft.gone = nil
		table.insert(draft.list, "y")
		local new = Immutable.Share(old, draft)
		t.equal(new.gone, nil)
		t.deepEqual(new.list, { "x", "y" })
	end)

	t.test("Share accepts frozen tables assigned into the draft", function()
		local old = Immutable.DeepFreeze({ a = { 1 } })
		local other = Immutable.DeepFreeze({ 1 })
		local draft = Immutable.DeepCopy(old)
		draft.a = other
		local new = Immutable.Share(old, draft)
		t.equal(new, old, "equal frozen subtable keeps old snapshot")
	end)

	t.test("DeepEqual", function()
		t.truthy(Immutable.DeepEqual({ a = { 1 } }, { a = { 1 } }))
		t.falsy(Immutable.DeepEqual({ a = { 1 } }, { a = { 1, 2 } }))
		t.falsy(Immutable.DeepEqual({ a = 1 }, { a = 1, b = 2 }))
	end)
end
