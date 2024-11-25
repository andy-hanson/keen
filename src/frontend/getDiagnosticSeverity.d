module frontend.getDiagnosticSeverity;

@safe @nogc pure nothrow:

import model.model;
import model.parseDiag;

DiagnosticSeverity getDiagnosticSeverity(in Diag a) =>
	a.matchIn!DiagnosticSeverity(
		(in DiagAliasNotAllowed) =>
			DiagnosticSeverity.checkError,
		(in DiagAssertOrForbidMessageIsThrow) =>
			DiagnosticSeverity.warning,
		(in DiagAssignmentNotAllowed) =>
			DiagnosticSeverity.checkError,
		(in DiagAutoFunError) =>
			DiagnosticSeverity.checkError,
		(in DiagBuiltinFunCantHaveBody) =>
			DiagnosticSeverity.checkError,
		(in DiagBuiltinUnsupported) =>
			DiagnosticSeverity.checkError,
		(in DiagCallMissingExtern) =>
			DiagnosticSeverity.checkError,
		(in DiagCallMultipleMatches) =>
			DiagnosticSeverity.checkError,
		(in DiagCallNoMatch) =>
			DiagnosticSeverity.checkError,
		(in DiagCallShouldUseSyntax) =>
			DiagnosticSeverity.warning,
		(in DiagCantCall) =>
			DiagnosticSeverity.checkError,
		(in DiagCaseDuplicate) =>
			DiagnosticSeverity.checkError,
		(in DiagCaseInvalidMemberType) =>
			DiagnosticSeverity.checkError,
		(in DiagCaseInvalidSumType) =>
			DiagnosticSeverity.checkError,
		(in DiagCaseMissingType) =>
			DiagnosticSeverity.checkError,
		(in DiagCharLiteralMustBeOneChar) =>
			DiagnosticSeverity.checkError,
		(in DiagCommonFunDuplicate) =>
			DiagnosticSeverity.checkError,
		(in DiagCommonFunMissing) =>
			DiagnosticSeverity.commonMissing,
		(in DiagCommonTypeMissing) =>
			DiagnosticSeverity.commonMissing,
		(in DiagCommonVarMissing) =>
			DiagnosticSeverity.commonMissing,
		(in DiagDestructureTypeMismatch) =>
			DiagnosticSeverity.checkError,
		(in DiagDuplicateDeclaration) =>
			DiagnosticSeverity.checkError,
		(in DiagDuplicateExports) =>
			DiagnosticSeverity.checkError,
		(in DiagDuplicateImportName) =>
			DiagnosticSeverity.warning,
		(in DiagDuplicateImports) =>
			DiagnosticSeverity.checkError,
		(in DiagEmptyEnumOrUnion) =>
			DiagnosticSeverity.checkError,
		(in DiagEnumBackingTypeInvalid) =>
			DiagnosticSeverity.checkError,
		(in DiagEnumDuplicateValue) =>
			DiagnosticSeverity.checkError,
		(in DiagExpectedTypeIsNotALambda) =>
			DiagnosticSeverity.checkError,
		(in DiagExternBodyMultiple) =>
			DiagnosticSeverity.checkError,
		(in DiagExternInvalidName) =>
			DiagnosticSeverity.checkError,
		(in DiagExternIsUnsafe) =>
			DiagnosticSeverity.warning,
		(in DiagExternRedundant) =>
			DiagnosticSeverity.warning,
		(in DiagExternFunVariadic) =>
			DiagnosticSeverity.checkError,
		(in DiagExternHasUnnecessaryLibraryName) =>
			DiagnosticSeverity.warning,
		(in DiagExternMissingLibraryName) =>
			DiagnosticSeverity.checkError,
		(in DiagExternRecordImplicitlyByVal) =>
			DiagnosticSeverity.checkError,
		(in DiagExternSumType) =>
			DiagnosticSeverity.checkError,
		(in DiagExternTypeError) =>
			DiagnosticSeverity.checkError,
		(in DiagFlagsSigned) =>
			DiagnosticSeverity.checkError,
		(in DiagFunctionWithSignatureNotFound) =>
			DiagnosticSeverity.checkError,
		(in DiagFunPointerExprMustBeName) =>
			DiagnosticSeverity.checkError,
		(in DiagFunPointerNotBare) =>
			DiagnosticSeverity.checkError,
		(in DiagIfThrow) =>
			DiagnosticSeverity.warning,
		(in DiagImportFileDiag) =>
			DiagnosticSeverity.importError,
		(in DiagImportRefersToNothing) =>
			DiagnosticSeverity.nameNotFound,
		(in DiagLambdaCantBeFunctionPointer) =>
			DiagnosticSeverity.checkError,
		(in DiagLambdaCantInferParamType) =>
			DiagnosticSeverity.checkError,
		(in DiagLambdaClosurePurity) =>
			DiagnosticSeverity.checkError,
		(in DiagLambdaMultipleMatch) =>
			DiagnosticSeverity.checkError,
		(in DiagLambdaNotExpected) =>
			DiagnosticSeverity.checkError,
		(in DiagLambdaTypeMissingParamType) =>
			DiagnosticSeverity.parseError,
		(in DiagLambdaTypeVariadic) =>
			DiagnosticSeverity.checkError,
		(in DiagLinkageWorseThanContainingFun) =>
			DiagnosticSeverity.checkError,
		(in DiagLinkageWorseThanContainingType) =>
			DiagnosticSeverity.checkError,
		(in DiagLiteralFloatAccuracy) =>
			DiagnosticSeverity.checkError,
		(in DiagLiteralMultipleMatch) =>
			DiagnosticSeverity.checkError,
		(in DiagLiteralNotExpected) =>
			DiagnosticSeverity.checkError,
		(in DiagLiteralOverflow) =>
			DiagnosticSeverity.checkError,
		(in DiagLocalIgnoredButMutable) =>
			DiagnosticSeverity.warning,
		(in DiagLocalNotMutable) =>
			DiagnosticSeverity.checkError,
		(in DiagLoopDisallowedBody) =>
			DiagnosticSeverity.checkError,
		(in DiagLoopWithoutBreak) =>
			DiagnosticSeverity.warning,
		(in DiagMainMissingExterns) =>
			DiagnosticSeverity.commonMissing,
		(in DiagMainTestMissing) =>
			DiagnosticSeverity.commonMissing,
		(in DiagMatchCaseDuplicate) =>
			DiagnosticSeverity.checkError,
		(in DiagMatchCaseForType) =>
			DiagnosticSeverity.checkError,
		(in DiagMatchCaseNameNotInEnum) =>
			DiagnosticSeverity.checkError,
		(in DiagMatchCaseNoValueForEnumOrSymbol) =>
			DiagnosticSeverity.checkError,
		(in DiagMatchCaseShouldUseIgnore) =>
			DiagnosticSeverity.warning,
		(in DiagMatchNeedsElse) =>
			DiagnosticSeverity.checkError,
		(in DiagMatchOnNonMatchable) =>
			DiagnosticSeverity.checkError,
		(in DiagMatchSumTypeCantInferTypeArgs) =>
			DiagnosticSeverity.checkError,
		(in DiagMatchSumTypeNoMember) =>
			DiagnosticSeverity.checkError,
		(in DiagMatchUnhandledCases) =>
			DiagnosticSeverity.checkError,
		(in DiagMatchUnnecessaryElse) =>
			DiagnosticSeverity.unusedCode,
		(in DiagMethodImplVisibility) =>
			DiagnosticSeverity.warning,
		(in DiagModifierConflict) =>
			DiagnosticSeverity.checkError,
		(in DiagModifierDuplicate) =>
			DiagnosticSeverity.warning,
		(in DiagModifierInvalid) =>
			DiagnosticSeverity.checkError,
		(in DiagModifierRedundantDueToDeclKind) =>
			DiagnosticSeverity.warning,
		(in DiagModifierRedundantDueToModifier) =>
			DiagnosticSeverity.warning,
		(in DiagModifierTypeArgInvalid) =>
			DiagnosticSeverity.checkError,
		(in DiagMutFieldNotAllowed) =>
			DiagnosticSeverity.checkError,
		(in DiagNameNotFound) =>
			DiagnosticSeverity.nameNotFound,
		(in DiagNeedsExpectedType) =>
			DiagnosticSeverity.checkError,
		(in DiagParamMissingType) =>
			DiagnosticSeverity.checkError,
		(in DiagParamMutable) =>
			DiagnosticSeverity.checkError,
		(in ParseDiag x) =>
			parseDiagSeverity(x),
		(in DiagPointerIsNative) =>
			DiagnosticSeverity.checkError,
		(in DiagPointerIsUnsafe) =>
			DiagnosticSeverity.warning,
		(in DiagPointerMutToConst) =>
			DiagnosticSeverity.checkError,
		(in DiagPointerUnsupported) =>
			DiagnosticSeverity.checkError,
		(in DiagPurityWorseThanParent) =>
			DiagnosticSeverity.checkError,
		(in DiagPurityWorseThanSumType) =>
			DiagnosticSeverity.checkError,
		(in DiagRecordFieldNeedsType) =>
			DiagnosticSeverity.checkError,
		(in DiagSharedArgIsNotLambda) =>
			DiagnosticSeverity.checkError,
		(in DiagSharedLambdaTypeIsNotShared) =>
			DiagnosticSeverity.checkError,
		(in DiagSharedLambdaUnused) =>
			DiagnosticSeverity.unusedCode,
		(in DiagSharedNotExpected) =>
			DiagnosticSeverity.checkError,
		(in DiagSpecMatchError) =>
			DiagnosticSeverity.checkError,
		(in DiagSpecNoMatch) =>
			DiagnosticSeverity.checkError,
		(in DiagSpecRecursion) =>
			DiagnosticSeverity.checkError,
		(in DiagSpecSigCantBeVariadic) =>
			DiagnosticSeverity.checkError,
		(in DiagSpecUseInvalid) =>
			DiagnosticSeverity.checkError,
		(in DiagStringLiteralInvalid) =>
			DiagnosticSeverity.checkError,
		(in DiagStorageMissingType) =>
			DiagnosticSeverity.checkError,
		(in DiagStructParamsSyntaxError) =>
			DiagnosticSeverity.parseError,
		(in DiagSumTypeListedMembersNonUnion) =>
			DiagnosticSeverity.checkError,
		(in DiagTestMissingBody) =>
			DiagnosticSeverity.checkError,
		(in DiagTrustedUnnecessary) =>
			DiagnosticSeverity.warning,
		(in DiagTupleTooBig) =>
			DiagnosticSeverity.checkError,
		(in DiagTypeAnnotationUnnecessary) =>
			DiagnosticSeverity.warning,
		(in DiagTypeConflict) =>
			DiagnosticSeverity.checkError,
		(in DiagTypeParamCantHaveTypeArgs) =>
			DiagnosticSeverity.checkError,
		(in DiagTypeParamsUnsupported) =>
			DiagnosticSeverity.checkError,
		(in DiagTypeShouldUseSyntax) =>
			DiagnosticSeverity.warning,
		(in DiagUnionMemberTypeParameter) =>
			DiagnosticSeverity.checkError,
		(in DiagUnsupportedSyntax) =>
			DiagnosticSeverity.checkError,
		(in DiagUnused) =>
			DiagnosticSeverity.unusedCode,
		(in DiagVarargsParamMustBeArray) =>
			DiagnosticSeverity.checkError,
		(in DiagVisibilityWarning) =>
			DiagnosticSeverity.unusedCode,
		(in DiagWithHasElse) =>
			DiagnosticSeverity.checkError,
		(in DiagWrongNumberTypeArgs) =>
			DiagnosticSeverity.checkError);

private:

DiagnosticSeverity parseDiagSeverity(in ParseDiag a) =>
	a.matchIn!DiagnosticSeverity(
		(in ParseDiagDocCommentUnused) =>
			DiagnosticSeverity.unusedCode,
		(in ParseDiagExpected) =>
			DiagnosticSeverity.parseError,
		(in ParseDiagFileNotUtf8) =>
			DiagnosticSeverity.importError,
		(in ParseDiagImportFileTypeNotSupported) =>
			DiagnosticSeverity.parseError,
		(in ParseDiagIndentNotDivisible) =>
			DiagnosticSeverity.parseError,
		(in ParseDiagIndentTooMuch) =>
			DiagnosticSeverity.parseError,
		(in ParseDiagIndentWrongCharacter) =>
			DiagnosticSeverity.parseError,
		(in ParseDiagInvalidStringEscape) =>
			DiagnosticSeverity.warning,
		(in ParseDiagMatchCaseInterpolated) =>
			DiagnosticSeverity.parseError,
		(in ParseDiagMissingInterpolated) =>
			DiagnosticSeverity.parseError,
		(in ParseDiagNeedsBlockCtx) =>
			DiagnosticSeverity.parseError,
		(in ReadFileDiag _) =>
			DiagnosticSeverity.importError,
		(in ParseDiagTrailingComma) =>
			DiagnosticSeverity.warning,
		(in ParseDiagTypeEmptyParens) =>
			DiagnosticSeverity.parseError,
		(in ParseDiagTypeTrailingMut) =>
			DiagnosticSeverity.parseError,
		(in ParseDiagTypeUnnecessaryParens) =>
			DiagnosticSeverity.warning,
		(in ParseDiagUnexpectedCharacter) =>
			DiagnosticSeverity.parseError,
		(in ParseDiagUnexpectedOperator) =>
			DiagnosticSeverity.parseError,
		(in ParseDiagUnexpectedToken) =>
			DiagnosticSeverity.parseError);
