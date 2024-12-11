module frontend.getDiagnosticSeverity;

@safe @nogc pure nothrow:

import model.model :
	Diag,
	DiagAliasNotAllowed,
	DiagAssertOrForbidMessageIsThrow,
	DiagAssignmentNotAllowed,
	DiagAutoFunBare,
	DiagAutoFunEnumOrFlagsToWrongStorage,
	DiagAutoFunParamNotSimple,
	DiagAutoFunSpecCorrupt,
	DiagAutoFunSpecFromWrongModule,
	DiagAutoFunTypeNotFullyVisible,
	DiagAutoFunWrongName,
	DiagAutoFunWrongParams,
	DiagAutoFunWrongParamType,
	DiagAutoFunWrongReturnType,
	DiagBuiltinFunCantHaveBody,
	DiagBuiltinUnsupported,
	DiagCallMissingExtern,
	DiagCallMultipleMatches,
	DiagCallNoMatch,
	DiagCallShouldUseSyntax,
	DiagCantCall,
	DiagCaseDuplicate,
	DiagCaseInvalidSumType,
	DiagCaseMissingType,
	DiagCaseTypeIsTemplate,
	DiagCharLiteralMustBeOneChar,
	DiagCommonFunDuplicate,
	DiagCommonFunMissing,
	DiagCommonTypeMissing,
	DiagCommonVarMissing,
	DiagDestructureTypeMismatch,
	DiagDuplicateDeclaration,
	DiagDuplicateExports,
	DiagDuplicateImportName,
	DiagDuplicateImports,
	DiagEmptyEnumOrUnion,
	DiagEnumBackingTypeInvalid,
	DiagEnumDuplicateValue,
	DiagExpectedTypeIsNotALambda,
	DiagExternBodyMultiple,
	DiagExternInvalidName,
	DiagExternIsUnsafe,
	DiagExternRedundant,
	DiagExternFunVariadic,
	DiagExternHasUnnecessaryLibraryName,
	DiagExternMissingLibraryName,
	DiagExternRecordImplicitlyByVal,
	DiagExternSumType,
	DiagExternTypeError,
	DiagFlagsSigned,
	DiagFunctionWithSignatureNotFound,
	DiagFunPointerExprMustBeName,
	DiagFunPointerNotBare,
	DiagIfThrow,
	DiagImportFile,
	DiagImportRefersToNothing,
	DiagLambdaCantBeFunctionPointer,
	DiagLambdaCantInferParamType,
	DiagLambdaClosurePurity,
	DiagLambdaMultipleMatch,
	DiagLambdaNotExpected,
	DiagLambdaTypeMissingParamType,
	DiagLambdaTypeVariadic,
	DiagLinkageWorseThanContainingFun,
	DiagLinkageWorseThanContainingType,
	DiagLiteralFloatAccuracy,
	DiagLiteralMultipleMatch,
	DiagLiteralNotExpected,
	DiagLiteralOverflow,
	DiagLocalIgnoredButMutable,
	DiagLocalNotMutable,
	DiagLoopDisallowedBody,
	DiagLoopWithoutBreak,
	DiagMainMissingExterns,
	DiagMainTestMissing,
	DiagMatchCaseDuplicate,
	DiagMatchCaseForType,
	DiagMatchCaseNameNotInEnum,
	DiagMatchCaseNoValueForEnumOrSymbol,
	DiagMatchCaseShouldUseIgnore,
	DiagMatchNeedsElse,
	DiagMatchOnNonMatchable,
	DiagMatchSumTypeCantInferTypeArgs,
	DiagMatchSumTypeNoMember,
	DiagMatchUnhandledEnumMembers,
	DiagMatchUnhandledUnionCaseTypes,
	DiagMatchUnnecessaryElse,
	DiagMethodImplVisibility,
	DiagModifierConflict,
	DiagModifierDuplicate,
	DiagModifierInvalid,
	DiagModifierRedundantDueToDeclKind,
	DiagModifierRedundantDueToModifier,
	DiagModifierTypeArgInvalid,
	DiagMutFieldNotAllowed,
	DiagNameNotFound,
	DiagNeedsExpectedType,
	DiagnosticSeverity,
	DiagParamMissingType,
	DiagParamMutable,
	DiagPointerIsNative,
	DiagPointerIsUnsafe,
	DiagPointerMutToConst,
	DiagPointerUnsupported,
	DiagPurityWorseThanParent,
	DiagPurityWorseThanSumType,
	DiagRecordFieldNeedsType,
	DiagSharedArgIsNotLambda,
	DiagSharedLambdaTypeIsNotShared,
	DiagSharedLambdaUnused,
	DiagSharedNotExpected,
	DiagSpecMatchMultiple,
	DiagSpecNoMatch,
	DiagSpecRecursion,
	DiagSpecSigCantBeVariadic,
	DiagSpecUseInvalid,
	DiagStringLiteralInvalid,
	DiagStorageMissingType,
	DiagStructParamsSyntaxError,
	DiagSumTypeListedMembersNonUnion,
	DiagTestMissingBody,
	DiagTrustedUnnecessary,
	DiagTupleTooBig,
	DiagTypeAnnotationUnnecessary,
	DiagTypeConflict,
	DiagTypeParamCantHaveTypeArgs,
	DiagTypeParamsUnsupported,
	DiagTypeShouldUseSyntax,
	DiagUnionMemberTypeParameter,
	DiagUnsupportedSyntax,
	DiagUnusedImport,
	DiagUnusedLocal,
	DiagUnusedPrivateDecl,
	DiagVarargsParamMustBeArray,
	DiagVisibilityWarning,
	DiagWithHasElse,
	DiagWrongNumberTypeArgs,
	existsDiagnostic,
	isFatal,
	Program,
	ProgramWithMain,
	UriAndDiagnostic;
import model.parseDiag :
	ParseDiag,
	ParseDiagDocCommentUnused,
	ParseDiagExpected,
	ParseDiagFileNotUtf8,
	ParseDiagImportFileTypeNotSupported,
	ParseDiagIndentNotDivisible,
	ParseDiagIndentTooMuch,
	ParseDiagIndentWrongCharacter,
	ParseDiagInvalidStringEscape,
	ParseDiagMatchCaseInterpolated,
	ParseDiagMissingInterpolated,
	ParseDiagNeedsBlockCtx,
	ParseDiagTrailingComma,
	ParseDiagTypeEmptyParens,
	ParseDiagTypeTrailingMut,
	ParseDiagTypeUnnecessaryParens,
	ParseDiagUnexpectedCharacter,
	ParseDiagUnexpectedOperator,
	ParseDiagUnexpectedToken,
	ReadFileDiag;
import util.col.array : isEmpty;

bool hasFatalDiagnostics(in Program a) =>
	existsDiagnostic(a, (in UriAndDiagnostic x) =>
		isFatal(getDiagnosticSeverity(x.kind)));
bool hasFatalDiagnostics(in ProgramWithMain a) =>
	hasFatalDiagnostics(a.program) || !isEmpty(a.mainFunDiagnostics);

DiagnosticSeverity getDiagnosticSeverity(in Diag a) =>
	a.matchIn!DiagnosticSeverity(
		(in DiagAliasNotAllowed _) =>
			DiagnosticSeverity.checkError,
		(in DiagAssertOrForbidMessageIsThrow _) =>
			DiagnosticSeverity.warning,
		(in DiagAssignmentNotAllowed _) =>
			DiagnosticSeverity.checkError,
		(in DiagAutoFunBare _) =>
			DiagnosticSeverity.checkError,
		(in DiagAutoFunEnumOrFlagsToWrongStorage _) =>
			DiagnosticSeverity.checkError,
		(in DiagAutoFunParamNotSimple _) =>
			DiagnosticSeverity.checkError,
		(in DiagAutoFunSpecCorrupt _) =>
			DiagnosticSeverity.checkError,
		(in DiagAutoFunSpecFromWrongModule _) =>
			DiagnosticSeverity.checkError,
		(in DiagAutoFunTypeNotFullyVisible _) =>
			DiagnosticSeverity.checkError,
		(in DiagAutoFunWrongName _) =>
			DiagnosticSeverity.checkError,
		(in DiagAutoFunWrongParams _) =>
			DiagnosticSeverity.checkError,
		(in DiagAutoFunWrongParamType _) =>
			DiagnosticSeverity.checkError,
		(in DiagAutoFunWrongReturnType _) =>
			DiagnosticSeverity.checkError,
		(in DiagBuiltinFunCantHaveBody _) =>
			DiagnosticSeverity.checkError,
		(in DiagBuiltinUnsupported _) =>
			DiagnosticSeverity.checkError,
		(in DiagCallMissingExtern _) =>
			DiagnosticSeverity.checkError,
		(in DiagCallMultipleMatches _) =>
			DiagnosticSeverity.checkError,
		(in DiagCallNoMatch _) =>
			DiagnosticSeverity.checkError,
		(in DiagCallShouldUseSyntax _) =>
			DiagnosticSeverity.warning,
		(in DiagCantCall _) =>
			DiagnosticSeverity.checkError,
		(in DiagCaseDuplicate _) =>
			DiagnosticSeverity.checkError,
		(in DiagCaseInvalidSumType _) =>
			DiagnosticSeverity.checkError,
		(in DiagCaseMissingType _) =>
			DiagnosticSeverity.checkError,
		(in DiagCaseTypeIsTemplate _) =>
			DiagnosticSeverity.checkError,
		(in DiagCharLiteralMustBeOneChar _) =>
			DiagnosticSeverity.checkError,
		(in DiagCommonFunDuplicate _) =>
			DiagnosticSeverity.checkError,
		(in DiagCommonFunMissing _) =>
			DiagnosticSeverity.commonMissing,
		(in DiagCommonTypeMissing _) =>
			DiagnosticSeverity.commonMissing,
		(in DiagCommonVarMissing _) =>
			DiagnosticSeverity.commonMissing,
		(in DiagDestructureTypeMismatch _) =>
			DiagnosticSeverity.checkError,
		(in DiagDuplicateDeclaration _) =>
			DiagnosticSeverity.checkError,
		(in DiagDuplicateExports _) =>
			DiagnosticSeverity.checkError,
		(in DiagDuplicateImportName _) =>
			DiagnosticSeverity.warning,
		(in DiagDuplicateImports _) =>
			DiagnosticSeverity.checkError,
		(in DiagEmptyEnumOrUnion _) =>
			DiagnosticSeverity.checkError,
		(in DiagEnumBackingTypeInvalid _) =>
			DiagnosticSeverity.checkError,
		(in DiagEnumDuplicateValue _) =>
			DiagnosticSeverity.checkError,
		(in DiagExpectedTypeIsNotALambda _) =>
			DiagnosticSeverity.checkError,
		(in DiagExternBodyMultiple _) =>
			DiagnosticSeverity.checkError,
		(in DiagExternInvalidName _) =>
			DiagnosticSeverity.checkError,
		(in DiagExternIsUnsafe _) =>
			DiagnosticSeverity.warning,
		(in DiagExternRedundant _) =>
			DiagnosticSeverity.warning,
		(in DiagExternFunVariadic _) =>
			DiagnosticSeverity.checkError,
		(in DiagExternHasUnnecessaryLibraryName _) =>
			DiagnosticSeverity.warning,
		(in DiagExternMissingLibraryName _) =>
			DiagnosticSeverity.checkError,
		(in DiagExternRecordImplicitlyByVal _) =>
			DiagnosticSeverity.checkError,
		(in DiagExternSumType _) =>
			DiagnosticSeverity.checkError,
		(in DiagExternTypeError _) =>
			DiagnosticSeverity.checkError,
		(in DiagFlagsSigned _) =>
			DiagnosticSeverity.checkError,
		(in DiagFunctionWithSignatureNotFound _) =>
			DiagnosticSeverity.checkError,
		(in DiagFunPointerExprMustBeName _) =>
			DiagnosticSeverity.checkError,
		(in DiagFunPointerNotBare _) =>
			DiagnosticSeverity.checkError,
		(in DiagIfThrow _) =>
			DiagnosticSeverity.warning,
		(in DiagImportFile _) =>
			DiagnosticSeverity.importError,
		(in DiagImportRefersToNothing _) =>
			DiagnosticSeverity.nameNotFound,
		(in DiagLambdaCantBeFunctionPointer _) =>
			DiagnosticSeverity.checkError,
		(in DiagLambdaCantInferParamType _) =>
			DiagnosticSeverity.checkError,
		(in DiagLambdaClosurePurity _) =>
			DiagnosticSeverity.checkError,
		(in DiagLambdaMultipleMatch _) =>
			DiagnosticSeverity.checkError,
		(in DiagLambdaNotExpected _) =>
			DiagnosticSeverity.checkError,
		(in DiagLambdaTypeMissingParamType _) =>
			DiagnosticSeverity.parseError,
		(in DiagLambdaTypeVariadic _) =>
			DiagnosticSeverity.checkError,
		(in DiagLinkageWorseThanContainingFun _) =>
			DiagnosticSeverity.checkError,
		(in DiagLinkageWorseThanContainingType _) =>
			DiagnosticSeverity.checkError,
		(in DiagLiteralFloatAccuracy _) =>
			DiagnosticSeverity.checkError,
		(in DiagLiteralMultipleMatch _) =>
			DiagnosticSeverity.checkError,
		(in DiagLiteralNotExpected _) =>
			DiagnosticSeverity.checkError,
		(in DiagLiteralOverflow _) =>
			DiagnosticSeverity.checkError,
		(in DiagLocalIgnoredButMutable _) =>
			DiagnosticSeverity.warning,
		(in DiagLocalNotMutable _) =>
			DiagnosticSeverity.checkError,
		(in DiagLoopDisallowedBody _) =>
			DiagnosticSeverity.checkError,
		(in DiagLoopWithoutBreak _) =>
			DiagnosticSeverity.warning,
		(in DiagMainMissingExterns _) =>
			DiagnosticSeverity.commonMissing,
		(in DiagMainTestMissing _) =>
			DiagnosticSeverity.commonMissing,
		(in DiagMatchCaseDuplicate _) =>
			DiagnosticSeverity.checkError,
		(in DiagMatchCaseForType _) =>
			DiagnosticSeverity.checkError,
		(in DiagMatchCaseNameNotInEnum _) =>
			DiagnosticSeverity.checkError,
		(in DiagMatchCaseNoValueForEnumOrSymbol _) =>
			DiagnosticSeverity.checkError,
		(in DiagMatchCaseShouldUseIgnore _) =>
			DiagnosticSeverity.warning,
		(in DiagMatchNeedsElse _) =>
			DiagnosticSeverity.checkError,
		(in DiagMatchOnNonMatchable _) =>
			DiagnosticSeverity.checkError,
		(in DiagMatchSumTypeCantInferTypeArgs _) =>
			DiagnosticSeverity.checkError,
		(in DiagMatchSumTypeNoMember _) =>
			DiagnosticSeverity.checkError,
		(in DiagMatchUnhandledEnumMembers _) =>
			DiagnosticSeverity.checkError,
		(in DiagMatchUnhandledUnionCaseTypes _) =>
			DiagnosticSeverity.checkError,
		(in DiagMatchUnnecessaryElse _) =>
			DiagnosticSeverity.unusedCode,
		(in DiagMethodImplVisibility _) =>
			DiagnosticSeverity.warning,
		(in DiagModifierConflict _) =>
			DiagnosticSeverity.checkError,
		(in DiagModifierDuplicate _) =>
			DiagnosticSeverity.warning,
		(in DiagModifierInvalid _) =>
			DiagnosticSeverity.checkError,
		(in DiagModifierRedundantDueToDeclKind _) =>
			DiagnosticSeverity.warning,
		(in DiagModifierRedundantDueToModifier _) =>
			DiagnosticSeverity.warning,
		(in DiagModifierTypeArgInvalid _) =>
			DiagnosticSeverity.checkError,
		(in DiagMutFieldNotAllowed _) =>
			DiagnosticSeverity.checkError,
		(in DiagNameNotFound _) =>
			DiagnosticSeverity.nameNotFound,
		(in DiagNeedsExpectedType _) =>
			DiagnosticSeverity.checkError,
		(in DiagParamMissingType _) =>
			DiagnosticSeverity.checkError,
		(in DiagParamMutable _) =>
			DiagnosticSeverity.checkError,
		(in ParseDiag x) =>
			parseDiagSeverity(x),
		(in DiagPointerIsNative _) =>
			DiagnosticSeverity.checkError,
		(in DiagPointerIsUnsafe _) =>
			DiagnosticSeverity.warning,
		(in DiagPointerMutToConst _) =>
			DiagnosticSeverity.checkError,
		(in DiagPointerUnsupported _) =>
			DiagnosticSeverity.checkError,
		(in DiagPurityWorseThanParent _) =>
			DiagnosticSeverity.checkError,
		(in DiagPurityWorseThanSumType _) =>
			DiagnosticSeverity.checkError,
		(in DiagRecordFieldNeedsType _) =>
			DiagnosticSeverity.checkError,
		(in DiagSharedArgIsNotLambda _) =>
			DiagnosticSeverity.checkError,
		(in DiagSharedLambdaTypeIsNotShared _) =>
			DiagnosticSeverity.checkError,
		(in DiagSharedLambdaUnused _) =>
			DiagnosticSeverity.unusedCode,
		(in DiagSharedNotExpected _) =>
			DiagnosticSeverity.checkError,
		(in DiagSpecMatchMultiple _) =>
			DiagnosticSeverity.checkError,
		(in DiagSpecNoMatch _) =>
			DiagnosticSeverity.checkError,
		(in DiagSpecRecursion _) =>
			DiagnosticSeverity.checkError,
		(in DiagSpecSigCantBeVariadic _) =>
			DiagnosticSeverity.checkError,
		(in DiagSpecUseInvalid _) =>
			DiagnosticSeverity.checkError,
		(in DiagStringLiteralInvalid _) =>
			DiagnosticSeverity.checkError,
		(in DiagStorageMissingType _) =>
			DiagnosticSeverity.checkError,
		(in DiagStructParamsSyntaxError _) =>
			DiagnosticSeverity.parseError,
		(in DiagSumTypeListedMembersNonUnion _) =>
			DiagnosticSeverity.checkError,
		(in DiagTestMissingBody _) =>
			DiagnosticSeverity.checkError,
		(in DiagTrustedUnnecessary _) =>
			DiagnosticSeverity.warning,
		(in DiagTupleTooBig _) =>
			DiagnosticSeverity.checkError,
		(in DiagTypeAnnotationUnnecessary _) =>
			DiagnosticSeverity.warning,
		(in DiagTypeConflict _) =>
			DiagnosticSeverity.checkError,
		(in DiagTypeParamCantHaveTypeArgs _) =>
			DiagnosticSeverity.checkError,
		(in DiagTypeParamsUnsupported _) =>
			DiagnosticSeverity.checkError,
		(in DiagTypeShouldUseSyntax _) =>
			DiagnosticSeverity.warning,
		(in DiagUnionMemberTypeParameter _) =>
			DiagnosticSeverity.checkError,
		(in DiagUnsupportedSyntax _) =>
			DiagnosticSeverity.checkError,
		(in DiagUnusedImport _) =>
			DiagnosticSeverity.unusedCode,
		(in DiagUnusedLocal _) =>
			DiagnosticSeverity.unusedCode,
		(in DiagUnusedPrivateDecl _) =>
			DiagnosticSeverity.unusedCode,
		(in DiagVarargsParamMustBeArray _) =>
			DiagnosticSeverity.checkError,
		(in DiagVisibilityWarning _) =>
			DiagnosticSeverity.unusedCode,
		(in DiagWithHasElse _) =>
			DiagnosticSeverity.checkError,
		(in DiagWrongNumberTypeArgs _) =>
			DiagnosticSeverity.checkError);

private:

DiagnosticSeverity parseDiagSeverity(in ParseDiag a) =>
	a.matchIn!DiagnosticSeverity(
		(in ParseDiagDocCommentUnused _) =>
			DiagnosticSeverity.unusedCode,
		(in ParseDiagExpected _) =>
			DiagnosticSeverity.parseError,
		(in ParseDiagFileNotUtf8 _) =>
			DiagnosticSeverity.importError,
		(in ParseDiagImportFileTypeNotSupported _) =>
			DiagnosticSeverity.parseError,
		(in ParseDiagIndentNotDivisible _) =>
			DiagnosticSeverity.parseError,
		(in ParseDiagIndentTooMuch _) =>
			DiagnosticSeverity.parseError,
		(in ParseDiagIndentWrongCharacter _) =>
			DiagnosticSeverity.parseError,
		(in ParseDiagInvalidStringEscape _) =>
			DiagnosticSeverity.warning,
		(in ParseDiagMatchCaseInterpolated _) =>
			DiagnosticSeverity.parseError,
		(in ParseDiagMissingInterpolated _) =>
			DiagnosticSeverity.parseError,
		(in ParseDiagNeedsBlockCtx _) =>
			DiagnosticSeverity.parseError,
		(in ReadFileDiag _) =>
			DiagnosticSeverity.importError,
		(in ParseDiagTrailingComma _) =>
			DiagnosticSeverity.warning,
		(in ParseDiagTypeEmptyParens _) =>
			DiagnosticSeverity.parseError,
		(in ParseDiagTypeTrailingMut _) =>
			DiagnosticSeverity.parseError,
		(in ParseDiagTypeUnnecessaryParens _) =>
			DiagnosticSeverity.warning,
		(in ParseDiagUnexpectedCharacter _) =>
			DiagnosticSeverity.parseError,
		(in ParseDiagUnexpectedOperator _) =>
			DiagnosticSeverity.parseError,
		(in ParseDiagUnexpectedToken _) =>
			DiagnosticSeverity.parseError);
