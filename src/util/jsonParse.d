module util.jsonParse;

@safe @nogc pure nothrow:

import util.alloc.alloc : Alloc;
import util.col.arrayBuilder : Builder, finish;
import util.json : Json, jsonNull;
import util.opt : force, has, none, Opt, some;
import util.string :
	CString, cStringIsEmpty, isDecimalDigit, isWhitespace, MutCString, takeChar, tryTakeChar, tryTakeChars;
import util.symbol : symbolOfString;
import util.writer : debugLogWithWriter, makeStringWithWriter, Writer;

Json mustParseJson(ref Alloc alloc, in CString source) {
	Opt!Json res = parseJson(alloc, source);
	return force(res);
}

Opt!Json parseJson(ref Alloc alloc, in CString source) {
	MutCString ptr = source;
	Opt!Json res = parseValue(alloc, ptr);
	skipWhitespace(ptr);
	return cStringIsEmpty(ptr) ? res : none!Json;
}

uint mustParseUint(CString s) {
	MutCString ptr = s;
	skipWhitespace(ptr);
	Json res = parseNumber(0, ptr);
	skipWhitespace(ptr);
	assert(cStringIsEmpty(ptr));
	return safeUintOfDouble(res.as!double);
}

uint asUint(in Json a) =>
	safeUintOfDouble(a.as!double);

private uint safeUintOfDouble(double a) {
	uint res = cast(int) a;
	assert((cast(double) res) == a);
	return res;
}

void skipWhitespace(scope ref MutCString ptr) {
	while (isWhitespace(*ptr))
		ptr++;
}

private:

Opt!Json parseValue(ref Alloc alloc, scope ref MutCString ptr) {
	skipWhitespace(ptr);
	char x = takeChar(ptr);
	switch (x) {
		case 'f':
			return tryTakeChars(ptr, "alse")
				? some(Json(false))
				: none!Json;
		case 'n':
			return tryTakeChars(ptr, "ull")
				? some(jsonNull)
				: none!Json;
		case 't':
			return tryTakeChars(ptr, "rue")
				? some(Json(true))
				: none!Json;
		case '"':
			Opt!string string = parseString(alloc, ptr);
			return has(string) ? some(Json(force(string))) : none!Json;
		case '[':
			return parseArray(alloc, ptr);
		case '{':
			return parseObject(alloc, ptr);
		case '0': .. case '9':
			return some(parseNumber(x - '0', ptr));
		default:
			return none!Json;
	}
}

Json parseNumber(double value, scope ref MutCString ptr) {
	// TODO: support floats?
	while (isDecimalDigit(*ptr))
		value = value * 10 + (takeChar(ptr) - '0');
	return Json(value);
}

Opt!string parseString(ref Alloc alloc, scope ref MutCString ptr) {
	bool ok = false;
	string res = makeStringWithWriter(alloc, (scope ref Writer writer) {
		//TODO: escaping
		while (true) {
			char x = takeChar(ptr);
			switch (x) {
				case '\0':
				case '\r':
				case '\n':
					debugLogWithWriter((scope ref Writer writer) {

					});
					return;
				case '"':
					ok = true;
					return;
				case '\\':
					Opt!char esc = escapedChar(takeChar(ptr));
					if (has(esc)) {
						writer ~= force(esc);
						break;
					} else
						return;
				default:
					writer ~= x;
					break;
			}
		}
	});
	return ok ? some(res) : none!string;
}

// TODO: share code with crow lexer?
Opt!char escapedChar(char escape) {
	switch (escape) {
		case '"':
			return some('"');
		case 'r':
			return some('\r');
		case 'n':
			return some('\n');
		case 't':
			return some('\t');
		case '\\':
			return some('\\');
		default:
			return none!char;
	}
}


Opt!Json parseArray(ref Alloc alloc, scope ref MutCString ptr) {
	Builder!Json res = Builder!Json(&alloc);
	while (true) {
		if (tryTakePunctuation(ptr, ']'))
			return some(Json(finish(res)));
		else {
			Opt!Json value = parseValue(alloc, ptr);
			if (has(value)) {
				res ~= force(value);
				if (tryTakePunctuation(ptr, ','))
					continue;
				else if (tryTakePunctuation(ptr, ']'))
					return some(Json(finish(res)));
				else
					return none!Json;
			} else
				return none!Json;
		}
	}
}

Opt!Json parseObject(ref Alloc alloc, scope ref MutCString ptr) {
	Builder!(Json.ObjectField) res = Builder!(Json.ObjectField)(&alloc);
	while (true) {
		if (tryTakePunctuation(ptr, '"')) {
			Opt!string keyString = parseString(alloc, ptr);
			if (has(keyString) && tryTakePunctuation(ptr, ':')) {
				Opt!Json value = parseValue(alloc, ptr);
				if (has(value)) {
					res ~= Json.ObjectField(symbolOfString(force(keyString)), force(value));
					if (tryTakePunctuation(ptr, ','))
						continue;
					else if (tryTakePunctuation(ptr, '}'))
						return some(Json(finish(res)));
					else
						return none!Json;
				} else
					return none!Json;
			} else
				return none!Json;
		} else if (tryTakePunctuation(ptr, '}'))
			return some(Json(finish(res)));
		else
			return none!Json;
	}
}

bool tryTakePunctuation(scope ref MutCString ptr, char expected) {
	skipWhitespace(ptr);
	return tryTakeChar(ptr, expected);
}
