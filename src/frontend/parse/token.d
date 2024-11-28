module frontend.parse.token;

@safe @nogc pure nothrow:

enum Token {
	alias_, // 'alias'
	arrowAccess, // '->'
	arrowLambda, // '=>'
	as, // 'as'
	assert_, // 'assert'
	at, // '@'
	bang, // '!'
	bare, // 'bare'
	break_, // 'break'
	builtin, // 'builtin'
	braceLeft, // '{'
	braceRight, // '}'
	bracketLeft, // '['
	bracketRight, // ']'
	byRef,
	byVal,
	case_, // 'case'
	catch_, // 'catch'
	colon, // ':'
	colon2, // '::'
	colonEqual, // ':='
	comma, // ','
	continue_, // 'continue'
	data, // 'data'
	do_, // 'do'
	dot, // '.'. // '..' is Operator.range
	dot3, // '...'
	elif, // 'elif'
	else_, // 'else'
	enum_, // 'enum'
	equal, // '='
	extern_, // 'extern'
	endOfFile,
	export_, // 'export'
	finally_, // 'finally'
	flags, // 'flags'
	for_, // 'for'
	forceShared, // 'force-shared'
	forbid, // 'forbid'
	forceCtx, // 'force-ctx'
	function_, // 'function'
	global, // 'global'
	guard, // 'guard'
	if_, // 'if'
	import_, // 'import'
	interface_, // 'interface'
	literalFloat, // Use asLiteralFloat
	literalIntegral, // Use asLiteralIntegral
	loop, // 'loop'
	match, // 'match'
	mut, // 'mut'
	name, // Any non-keyword, non-operator name; use TokenAndData.asSymbol with this
	nameAfterBang, // '!name'
	// Tokens for a name with '!', ':', ':=', or '=' on the end.
	nameBang,
	nameOrOperatorColonEquals, // 'TokenAndData.asSymbol' does NOT include the ':='
	nameOrOperatorEquals, // 'TokenAndData.asSymbol' DOES include the '='
	// End of line followed by another line at lesser indentation.
	// There will be one of these tokens for each reduced indent level, followed by a 'newline' token.
	newlineDedent,
	// End of line followed by another line at 1 greater indent level.
	// Unlike 'newlineDedent', this is not followed by a 'newlineSameIndent' token.
	newlineIndent,
	// end of line followed by another line at the same indent level.
	newlineSameIndent,
	nominal, // 'nominal'
	noStd, // 'no-std'
	operator, // Any operator; use TokenAndData.asSymbol with this
	packed, // 'packed'
	parenLeft, // '('
	parenRight, // ')'
	pure_, // 'pure'
	question, // '?'
	questionDot, // '?.'
	questionBracket, // '?['
	questionEqual, // '?='
	quoteBar, // '|', only if this is the first non-whitespace on its line. Otherwise that will be an operator.
	quoteDouble, // '"'
	quoteDouble3, // '"""'
	quotedText, // Fake token to be the peek after the '"'
	record, // 'record'
	region, // 'region'
	reserved, // any reserved word
	semicolon, // ';'
	shared_, // 'shared'
	spec, // 'spec'
	storage, // 'storage'
	summon, // 'summon'
	test, // 'test'
	thread_local, // 'thread-local'
	throw_, // 'throw'
	trusted, // 'trusted'
	try_, // 'try'
	unexpectedCharacter, // Any unexpected character
	underscore, // '_'
	union_, // 'union'
	unless, // 'unless'
	unsafe, // 'unsafe'
	until, // 'until'
	variant, // 'variant'
	while_, // 'while'
	with_, // 'with'
}