import { z } from "zod";

export const requestSchema = z.object({
  jsonrpc: z.literal("2.0"),
  id: z.union([z.string(), z.number()]),
  method: z.string().min(1).max(128),
  params: z.unknown().optional(),
});

export type RPCRequest = z.infer<typeof requestSchema>;

export interface RPCSuccess {
  jsonrpc: "2.0";
  id: string | number;
  result: unknown;
}

export interface RPCFailure {
  jsonrpc: "2.0";
  id: string | number | null;
  error: {
    code: number;
    message: string;
    data?: { diagnosticCode: string; queryDetails?: QueryFailureDetails };
  };
}

export type RPCResponse = RPCSuccess | RPCFailure;

export interface QueryFailureDetails {
  message: string;
  sqlState: string | null;
  position: number | null;
  statementIndex: number | null;
  transactionState: string;
}

export class RPCError extends Error {
  constructor(
    readonly code: number,
    message: string,
    readonly diagnosticCode: string,
    readonly queryDetails?: QueryFailureDetails,
  ) {
    super(message);
  }
}
