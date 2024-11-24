module frontend.check.checkUtil;

@safe @nogc pure nothrow:

import frontend.check.checkCtx : addDiag, CheckCtx;
import model.ast : LiteralIntegralAndRange;
import model.diag : Diag;
import model.model : IntegralType, maxValue, minValue;
import util.integralValues : IntegralValue;

IntegralValue checkLiteralIntegralValue(ref CheckCtx ctx, IntegralType type, LiteralIntegralAndRange ast) {
	if (ast.literal.overflow || literalNatOrIntOverflows(type, ast.literal.isSigned, ast.literal.value))
		addDiag(ctx, ast.range, Diag(Diag.LiteralOverflow(type)));
	return ast.literal.value;
}

private:

bool literalNatOrIntOverflows(IntegralType type, bool isSigned, IntegralValue value) =>
	isSigned
		? (value.asSigned < minValue(type) || (value.asSigned > 0 && value.asSigned > maxValue(type)))
		: value.asUnsigned > maxValue(type);
