module frontend.config;

@safe @nogc pure nothrow:

import model.model : Config, ConfigExternUris, configForDiag, ConfigImportUris, Diag, Diagnostic;
import util.alloc.alloc : Alloc;
import util.col.arrayBuilder : ArrayBuilder, finish;
import util.col.array : fold;
import util.col.map : Map;
import util.col.mapBuilder : finishMap, MapBuilder, tryAddToMap;
import util.json : Json, JsonNull;
import util.opt : force, has, none, Opt, optIf, some;
import util.jsonParse : parseJson;
import util.string : CString;
import util.symbol : Symbol, symbol;
import util.uri : bogusUri, parentOrEmpty, parseUriWithCwd, Uri;
import util.util : todo;

Config parseConfig(ref Alloc alloc, Uri configUri, in CString text) {
	ArrayBuilder!Diagnostic diagsBuilder;
	Opt!Json json = parseJson(alloc, text); // TODO: this should take diagsBuilder
	if (has(json) && force(json).isA!(Json.Object)) {
		ConfigContent content = parseConfigRecur(
			alloc, parentOrEmpty(configUri), diagsBuilder, force(json).as!(Json.Object));
		return Config(some(configUri), finish(alloc, diagsBuilder), content.include, content.extern_);
	} else
		return configForDiag(alloc, configUri, todo!Diag("diag -- bad JSON"));
}

private:

ConfigContent emptyConfigContent() =>
	ConfigContent(ConfigImportUris(), ConfigExternUris());

ConfigContent withInclude(ConfigContent a, ConfigImportUris include) =>
	ConfigContent(include, a.extern_);

ConfigContent withExtern(ConfigContent a, ConfigExternUris extern_) =>
	ConfigContent(a.include, extern_);

struct ConfigContent {
	ConfigImportUris include;
	ConfigExternUris extern_;
}

ConfigContent parseConfigRecur(
	ref Alloc alloc,
	Uri dirContainingConfig,
	scope ref ArrayBuilder!Diagnostic diags,
	in Json.Object fields,
) =>
	fold!(ConfigContent, Json.ObjectField)(emptyConfigContent, fields, (ConfigContent cur, in Json.ObjectField field) {
		Json value = field.value;
		switch (field.key.value) {
			case symbol!"include".value:
				return withInclude(cur, parseInclude(alloc, dirContainingConfig, diags, value));
			case symbol!"extern".value:
				return withExtern(cur, parseExtern(alloc, dirContainingConfig, diags, value));
			default:
				todo!void("diag -- bad key");
				return cur;
		}
	});

ConfigImportUris parseInclude(
	ref Alloc alloc,
	Uri dirContainingConfig,
	scope ref ArrayBuilder!Diagnostic diags,
	in Json json,
) =>
	parseSymbolMap!Uri(alloc, diags, json, (in Json value) =>
		parseUriOrBogus(dirContainingConfig, diags, value));

ConfigExternUris parseExtern(
	ref Alloc alloc,
	Uri dirContainingConfig,
	scope ref ArrayBuilder!Diagnostic diags,
	in Json json,
) =>
	parseSymbolMap!(Opt!Uri)(alloc, diags, json, (in Json value) =>
		optIf(!value.isA!JsonNull, () =>
			parseUriOrBogus(dirContainingConfig, diags, value)));

Uri parseUriOrBogus(Uri dirContainingConfig, scope ref ArrayBuilder!Diagnostic diags, in Json value) {
	Opt!Uri res = parseUri(dirContainingConfig, diags, value);
	return has(res) ? force(res) : bogusUri();
}

Opt!Uri parseUri(
	Uri dirContainingConfig,
	scope ref ArrayBuilder!Diagnostic diags,
	in Json json,
) {
	if (json.isA!string)
		return some(parseUriWithCwd(dirContainingConfig, json.as!string));
	else {
		todo!void("diag -- 'include' values should be strings");
		return none!Uri;
	}
}

Map!(Symbol, T) parseSymbolMap(T)(
	ref Alloc alloc,
	scope ref ArrayBuilder!Diagnostic diags,
	in Json json,
	in T delegate(in Json) @safe @nogc pure nothrow cbValue,
) {
	MapBuilder!(Symbol, T) res;
	if (json.isA!(Json.Object)) {
		foreach (ref Json.ObjectField field; json.as!(Json.Object)) {
			T value = cbValue(field.value);
			Opt!T before = tryAddToMap(alloc, res, field.key, value);
			if (has(before))
				todo!void("diag -- duplicate include key");
		}
	} else
		todo!void("diag -- include should be an object");
	return finishMap(alloc, res);
}
