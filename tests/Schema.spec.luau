local Schema = require("../src/shared/Data/Schema")
local Validate = require("../src/shared/Data/Validate")

return function(t)
	t.test("template passes its own validator", function()
		local ok, err = Validate.Check(Schema.Validator, Schema.Template)
		t.truthy(ok, err)
	end)

	t.test("template is deep-frozen", function()
		t.truthy(table.isfrozen(Schema.Template))
		t.truthy(table.isfrozen(Schema.Template.Inventory.Items))
		t.errors(function()
			(Schema.Template :: any).Coins = 5
		end)
	end)

	t.test("template carries the current version", function()
		t.equal(Schema.Template[Schema.VersionKey], Schema.Version)
	end)

	t.test("numeric fields are numbers in the template", function()
		for field in Schema.NumericFields do
			t.equal(type(Schema.Template[field]), "number", field)
		end
	end)

	t.test("ToPublic only exposes public fields", function()
		local public = Schema.ToPublic(Schema.Template)
		t.deepEqual(public, { Level = 1 })
	end)
end
