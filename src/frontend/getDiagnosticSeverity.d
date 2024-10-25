module frontend.getDiagnosticSeverity;

@safe @nogc pure nothrow:

import model.diag : Diag, DiagnosticSeverity, ReadFileDiag;
import model.parseDiag : ParseDiag;

DiagnosticSeverity getDiagnosticSeverity(in Diag a) =>
	a.matchIn!DiagnosticSeverity(
		(in Diag.AliasNotAllowed) =>
			DiagnosticSeverity.checkError,
		(in Diag.AssertOrForbidMessageIsThrow) =>
			DiagnosticSeverity.warning,
		(in Diag.AssignmentNotAllowed) =>
			DiagnosticSeverity.checkError,
		(in Diag.AutoFunError) =>
			DiagnosticSeverity.checkError,
		(in Diag.BuiltinFunCantHaveBody) =>
			DiagnosticSeverity.checkError,
		(in Diag.BuiltinUnsupported) =>
			DiagnosticSeverity.checkError,
		(in Diag.CallMissingExtern) =>
			DiagnosticSeverity.checkError,
		(in Diag.CallMultipleMatches) =>
			DiagnosticSeverity.checkError,
		(in Diag.CallNoMatch) =>
			DiagnosticSeverity.checkError,
		(in Diag.CallShouldUseSyntax) =>
			DiagnosticSeverity.warning,
		(in Diag.CantCall) =>
			DiagnosticSeverity.checkError,
		(in Diag.CharLiteralMustBeOneChar) =>
			DiagnosticSeverity.checkError,
		(in Diag.CommonFunDuplicate) =>
			DiagnosticSeverity.checkError,
		(in Diag.CommonFunMissing) =>
			DiagnosticSeverity.commonMissing,
		(in Diag.CommonTypeMissing) =>
			DiagnosticSeverity.commonMissing,
		(in Diag.CommonVarMissing) =>
			DiagnosticSeverity.commonMissing,
		(in Diag.DestructureTypeMismatch) =>
			DiagnosticSeverity.checkError,
		(in Diag.DuplicateDeclaration) =>
			DiagnosticSeverity.checkError,
		(in Diag.DuplicateExports) =>
			DiagnosticSeverity.checkError,
		(in Diag.DuplicateImportName) =>
			DiagnosticSeverity.warning,
		(in Diag.DuplicateImports) =>
			DiagnosticSeverity.checkError,
		(in Diag.EmptyEnumOrUnion) =>
			DiagnosticSeverity.checkError,
		(in Diag.EnumBackingTypeInvalid) =>
			DiagnosticSeverity.checkError,
		(in Diag.EnumDuplicateValue) =>
			DiagnosticSeverity.checkError,
		(in Diag.ExpectedTypeIsNotALambda) =>
			DiagnosticSeverity.checkError,
		(in Diag.ExternBodyMultiple) =>
			DiagnosticSeverity.checkError,
		(in Diag.ExternInvalidName) =>
			DiagnosticSeverity.checkError,
		(in Diag.ExternIsUnsafe) =>
			DiagnosticSeverity.warning,
		(in Diag.ExternRedundant) =>
			DiagnosticSeverity.warning,
		(in Diag.ExternFunVariadic) =>
			DiagnosticSeverity.checkError,
		(in Diag.ExternHasUnnecessaryLibraryName) =>
			DiagnosticSeverity.warning,
		(in Diag.ExternMissingLibraryName) =>
			DiagnosticSeverity.checkError,
		(in Diag.ExternRecordImplicitlyByVal) =>
			DiagnosticSeverity.checkError,
		(in Diag.ExternTypeError) =>
			DiagnosticSeverity.checkError,
		(in Diag.ExternUnion) =>
			DiagnosticSeverity.checkError,
		(in Diag.FlagsSigned) =>
			DiagnosticSeverity.checkError,
		(in Diag.FunctionWithSignatureNotFound) =>
			DiagnosticSeverity.checkError,
		(in Diag.FunPointerExprMustBeName) =>
			DiagnosticSeverity.checkError,
		(in Diag.FunPointerNotBare) =>
			DiagnosticSeverity.checkError,
		(in Diag.IfThrow) =>
			DiagnosticSeverity.warning,
		(in Diag.ImportFileDiag) =>
			DiagnosticSeverity.importError,
		(in Diag.ImportRefersToNothing) =>
			DiagnosticSeverity.nameNotFound,
		(in Diag.LambdaCantBeFunctionPointer) =>
			DiagnosticSeverity.checkError,
		(in Diag.LambdaCantInferParamType) =>
			DiagnosticSeverity.checkError,
		(in Diag.LambdaClosurePurity) =>
			DiagnosticSeverity.checkError,
		(in Diag.LambdaMultipleMatch) =>
			DiagnosticSeverity.checkError,
		(in Diag.LambdaNotExpected) =>
			DiagnosticSeverity.checkError,
		(in Diag.LambdaTypeMissingParamType) =>
			DiagnosticSeverity.parseError,
		(in Diag.LambdaTypeVariadic) =>
			DiagnosticSeverity.checkError,
		(in Diag.LinkageWorseThanContainingFun) =>
			DiagnosticSeverity.checkError,
		(in Diag.LinkageWorseThanContainingType) =>
			DiagnosticSeverity.checkError,
		(in Diag.LiteralFloatAccuracy) =>
			DiagnosticSeverity.checkError,
		(in Diag.LiteralMultipleMatch) =>
			DiagnosticSeverity.checkError,
		(in Diag.LiteralNotExpected) =>
			DiagnosticSeverity.checkError,
		(in Diag.LiteralOverflow) =>
			DiagnosticSeverity.checkError,
		(in Diag.LocalIgnoredButMutable) =>
			DiagnosticSeverity.warning,
		(in Diag.LocalNotMutable) =>
			DiagnosticSeverity.checkError,
		(in Diag.LoopDisallowedBody) =>
			DiagnosticSeverity.checkError,
		(in Diag.LoopWithoutBreak) =>
			DiagnosticSeverity.warning,
		(in Diag.MainMissingExterns) =>
			DiagnosticSeverity.commonMissing,
		(in Diag.MainTestMissing) =>
			DiagnosticSeverity.commonMissing,
		(in Diag.MatchCaseDuplicate) =>
			DiagnosticSeverity.checkError,
		(in Diag.MatchCaseForType) =>
			DiagnosticSeverity.checkError,
		(in Diag.MatchCaseNameDoesNotMatch) =>
			DiagnosticSeverity.checkError,
		(in Diag.MatchCaseNoValueForEnumOrSymbol) =>
			DiagnosticSeverity.checkError,
		(in Diag.MatchCaseShouldUseIgnore) =>
			DiagnosticSeverity.warning,
		(in Diag.MatchNeedsElse) =>
			DiagnosticSeverity.checkError,
		(in Diag.MatchOnNonMatchable) =>
			DiagnosticSeverity.checkError,
		(in Diag.MatchUnhandledCases) =>
			DiagnosticSeverity.checkError,
		(in Diag.MatchUnnecessaryElse) =>
			DiagnosticSeverity.unusedCode,
		(in Diag.MatchVariantCantInferTypeArgs) =>
			DiagnosticSeverity.checkError,
		(in Diag.MatchVariantNoMember) =>
			DiagnosticSeverity.checkError,
		(in Diag.ModifierConflict) =>
			DiagnosticSeverity.checkError,
		(in Diag.ModifierDuplicate) =>
			DiagnosticSeverity.warning,
		(in Diag.ModifierInvalid) =>
			DiagnosticSeverity.checkError,
		(in Diag.ModifierRedundantDueToDeclKind) =>
			DiagnosticSeverity.warning,
		(in Diag.ModifierRedundantDueToModifier) =>
			DiagnosticSeverity.warning,
		(in Diag.ModifierTypeArgInvalid) =>
			DiagnosticSeverity.checkError,
		(in Diag.MutFieldNotAllowed) =>
			DiagnosticSeverity.checkError,
		(in Diag.NameNotFound) =>
			DiagnosticSeverity.nameNotFound,
		(in Diag.NeedsExpectedType) =>
			DiagnosticSeverity.checkError,
		(in Diag.ParamMissingType) =>
			DiagnosticSeverity.checkError,
		(in Diag.ParamMutable) =>
			DiagnosticSeverity.checkError,
		(in ParseDiag x) =>
			parseDiagSeverity(x),
		(in Diag.PointerIsNative) =>
			DiagnosticSeverity.checkError,
		(in Diag.PointerIsUnsafe) =>
			DiagnosticSeverity.warning,
		(in Diag.PointerMutToConst) =>
			DiagnosticSeverity.checkError,
		(in Diag.PointerUnsupported) =>
			DiagnosticSeverity.checkError,
		(in Diag.PurityWorseThanParent) =>
			DiagnosticSeverity.checkError,
		(in Diag.PurityWorseThanVariant) =>
			DiagnosticSeverity.checkError,
		(in Diag.RecordFieldNeedsType) =>
			DiagnosticSeverity.checkError,
		(in Diag.SharedArgIsNotLambda) =>
			DiagnosticSeverity.checkError,
		(in Diag.SharedLambdaTypeIsNotShared) =>
			DiagnosticSeverity.checkError,
		(in Diag.SharedLambdaUnused) =>
			DiagnosticSeverity.unusedCode,
		(in Diag.SharedNotExpected) =>
			DiagnosticSeverity.checkError,
		(in Diag.SpecMatchError) =>
			DiagnosticSeverity.checkError,
		(in Diag.SpecNoMatch) =>
			DiagnosticSeverity.checkError,
		(in Diag.SpecRecursion) =>
			DiagnosticSeverity.checkError,
		(in Diag.SpecSigCantBeVariadic) =>
			DiagnosticSeverity.checkError,
		(in Diag.SpecUseInvalid) =>
			DiagnosticSeverity.checkError,
		(in Diag.StringLiteralInvalid) =>
			DiagnosticSeverity.checkError,
		(in Diag.StorageMissingType) =>
			DiagnosticSeverity.checkError,
		(in Diag.StructParamsSyntaxError) =>
			DiagnosticSeverity.parseError,
		(in Diag.TestMissingBody) =>
			DiagnosticSeverity.checkError,
		(in Diag.TrustedUnnecessary) =>
			DiagnosticSeverity.warning,
		(in Diag.TupleTooBig) =>
			DiagnosticSeverity.checkError,
		(in Diag.TypeAnnotationUnnecessary) =>
			DiagnosticSeverity.warning,
		(in Diag.TypeConflict) =>
			DiagnosticSeverity.checkError,
		(in Diag.TypeParamCantHaveTypeArgs) =>
			DiagnosticSeverity.checkError,
		(in Diag.TypeParamsUnsupported) =>
			DiagnosticSeverity.checkError,
		(in Diag.TypeShouldUseSyntax) =>
			DiagnosticSeverity.warning,
		(in Diag.UnsupportedSyntax) =>
			DiagnosticSeverity.checkError,
		(in Diag.Unused) =>
			DiagnosticSeverity.unusedCode,
		(in Diag.VarargsParamMustBeArray) =>
			DiagnosticSeverity.checkError,
		(in Diag.VariantMemberIsTemplate) =>
			DiagnosticSeverity.checkError,
		(in Diag.VariantMemberMissingVariant) =>
			DiagnosticSeverity.checkError,
		(in Diag.VariantMemberMultiple) =>
			DiagnosticSeverity.checkError,
		(in Diag.VariantMemberOfNonVariant) =>
			DiagnosticSeverity.checkError,
		(in Diag.VariantMethodImplVisibility) =>
			DiagnosticSeverity.warning,
		(in Diag.VisibilityWarning) =>
			DiagnosticSeverity.unusedCode,
		(in Diag.WithHasElse) =>
			DiagnosticSeverity.checkError,
		(in Diag.WrongNumberTypeArgs) =>
			DiagnosticSeverity.checkError);

private:

DiagnosticSeverity parseDiagSeverity(in ParseDiag a) =>
	a.matchIn!DiagnosticSeverity(
		(in ParseDiag.DocCommentUnused) =>
			DiagnosticSeverity.unusedCode,
		(in ParseDiag.Expected) =>
			DiagnosticSeverity.parseError,
		(in ParseDiag.FileNotUtf8) =>
			DiagnosticSeverity.importError,
		(in ParseDiag.ImportFileTypeNotSupported) =>
			DiagnosticSeverity.parseError,
		(in ParseDiag.IndentNotDivisible) =>
			DiagnosticSeverity.parseError,
		(in ParseDiag.IndentTooMuch) =>
			DiagnosticSeverity.parseError,
		(in ParseDiag.IndentWrongCharacter) =>
			DiagnosticSeverity.parseError,
		(in ParseDiag.InvalidStringEscape) =>
			DiagnosticSeverity.warning,
		(in ParseDiag.MatchCaseInterpolated) =>
			DiagnosticSeverity.parseError,
		(in ParseDiag.MissingInterpolated) =>
			DiagnosticSeverity.parseError,
		(in ParseDiag.NeedsBlockCtx) =>
			DiagnosticSeverity.parseError,
		(in ReadFileDiag _) =>
			DiagnosticSeverity.importError,
		(in ParseDiag.TrailingComma) =>
			DiagnosticSeverity.warning,
		(in ParseDiag.TypeEmptyParens) =>
			DiagnosticSeverity.parseError,
		(in ParseDiag.TypeTrailingMut) =>
			DiagnosticSeverity.parseError,
		(in ParseDiag.TypeUnnecessaryParens) =>
			DiagnosticSeverity.warning,
		(in ParseDiag.UnexpectedCharacter) =>
			DiagnosticSeverity.parseError,
		(in ParseDiag.UnexpectedOperator) =>
			DiagnosticSeverity.parseError,
		(in ParseDiag.UnexpectedToken) =>
			DiagnosticSeverity.parseError);
