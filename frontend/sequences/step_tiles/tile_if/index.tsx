import * as React from "react";
import { t } from "i18next";
import { DropDownItem, NULL_CHOICE } from "../../../ui/index";
import { TaggedSequence, VariableDeclaration } from "farmbot";
import { If, Execute, Nothing } from "farmbot/dist";
import { ResourceIndex } from "../../../resources/interfaces";
import { selectAllSequences, findSequenceById } from "../../../resources/selectors";
import { isRecursive } from "../index";
import { If_ } from "./if";
import { ThenElse } from "./then_else";
import { defensiveClone } from "../../../util";
import { overwrite } from "../../../api/crud";
import { ToolTips } from "../../../constants";
import { StepWrapper, StepHeader, StepContent } from "../../step_ui/index";
import {
  sensorsAsDropDowns, peripheralsAsDropDowns, pinDropdowns
} from "../pin_and_peripheral_support";
import { ShouldDisplay, Feature } from "../../../devices/interfaces";
import { isNumber, isString } from "lodash";
import { addOrEditVarDeclaration } from "../../locals_list/declaration_support";

export interface IfParams {
  currentSequence: TaggedSequence;
  currentStep: If;
  dispatch: Function;
  index: number;
  resources: ResourceIndex;
  shouldDisplay?: ShouldDisplay;
  confirmStepDeletion: boolean;
}

export interface ThenElseParams extends IfParams {
  thenElseKey: "_then" | "_else";
}

export type Operator = "lhs"
  | "op"
  | "rhs"
  | "_then"
  | "_else";

export const LHSOptions =
  (resources: ResourceIndex, shouldDisplay: ShouldDisplay
  ): DropDownItem[] => [
      { heading: true, label: t("Positions"), value: 0 },
      { value: "x", label: t("X position"), headingId: "Position" },
      { value: "y", label: t("Y position"), headingId: "Position" },
      { value: "z", label: t("Z position"), headingId: "Position" },
      ...(shouldDisplay(Feature.named_pins) ? peripheralsAsDropDowns(resources) : []),
      ...(shouldDisplay(Feature.named_pins) ? sensorsAsDropDowns(resources) : []),
      ...pinDropdowns(n => `pin${n}`),
    ];

export const operatorOptions: DropDownItem[] = [
  { value: "<", label: t("is less than") },
  { value: ">", label: t("is greater than") },
  { value: "is", label: t("is equal to") },
  { value: "not", label: t("is not equal to") },
  { value: "is_undefined", label: t("is unknown") }
];

export function seqDropDown(i: ResourceIndex) {
  const results: DropDownItem[] = [];
  selectAllSequences(i)
    .map(function (x) {
      const { body } = x;
      if (isNumber(body.id)) {
        results.push({ label: body.name, value: body.id });
      }
    });
  return results;
}

export function InnerIf(props: IfParams) {
  const {
    index,
    dispatch,
    currentStep,
    currentSequence,
    confirmStepDeletion,
  } = props;
  const recursive = isRecursive(currentStep, currentSequence);
  const className = "if-step";
  return <StepWrapper>
    <StepHeader
      className={className}
      helpText={ToolTips.IF}
      currentSequence={currentSequence}
      currentStep={currentStep}
      dispatch={dispatch}
      index={index}
      confirmStepDeletion={confirmStepDeletion}>
      {recursive &&
        <span>
          <i className="fa fa-exclamation-triangle"></i>
          &nbsp;{t("Recursive condition.")}
        </span>
      }
    </StepHeader>
    <StepContent className={className}>
      <If_ {...props} />
      <ThenElse thenElseKey={"_then"} {...props} />
      <ThenElse thenElseKey={"_else"} {...props} />
    </StepContent>
  </StepWrapper>;
}

/** Creates a function that can be used in the `onChange` event of a _else or
 * _then block in the sequence editor.
 */
export let IfBlockDropDownHandler = (props: ThenElseParams) => {

  const { dispatch, index, thenElseKey } = props;
  const step = props.currentStep;
  const sequence = props.currentSequence;
  const block = step.args[thenElseKey];
  const selectedItem = () => {
    if (block.kind === "nothing") {
      return NULL_CHOICE;
    } else {
      const value = (block.kind === "execute") && block.args.sequence_id;
      const label = value && findSequenceById(props.resources, value).body.name;
      if (isNumber(value) && isString(label)) {
        return { label, value };
      } else {
        throw new Error("Failed type assertion");
      }
    }
  };

  function overwriteStep(input: Execute | Nothing) {
    const update = defensiveClone(step);
    const nextSequence = defensiveClone(sequence).body;
    update.args[thenElseKey] = input;
    (nextSequence.body || [])[index] = update;
    dispatch(overwrite(sequence, nextSequence));
  }

  function onChange(e: DropDownItem) {
    if (e.value && isNumber(e.value)) {
      const v = e.value;
      overwriteStep({ kind: "execute", args: { sequence_id: v } });
    } else {
      overwriteStep({ kind: "nothing", args: {} });
    }
  }

  const sequenceId = selectedItem().value;
  const calleeUuid = sequenceId ?
    findSequenceById(props.resources, sequenceId).uuid : undefined;
  const calledSequenceVariableData = calleeUuid ?
    props.resources.sequenceMetas[calleeUuid] : undefined;

  /** Replaces the execute step body with a new array of declarations. */
  const assignVariable = (declarations: VariableDeclaration[]) =>
    (variable: VariableDeclaration) => {
      block.body = addOrEditVarDeclaration(declarations, variable);
      overwriteStep(block);
    };

  return { onChange, selectedItem, calledSequenceVariableData, assignVariable };
};
