/** Presentation quantities derived from the component contract. */
export interface ComponentStock {
  gas_quantity: number;
  bottle_quantity: number;
  unit_quantity: number;
}

export function stockDisplay<T extends ComponentStock>(stock: T) {
  return {
    ...stock,
    filled_quantity: stock.gas_quantity + stock.unit_quantity,
    empty_quantity: stock.bottle_quantity - stock.gas_quantity,
  };
}

export interface ComponentMovement {
  gas_change: number;
  bottle_change: number;
  unit_change: number;
}

export function movementDisplay<T extends ComponentMovement>(movement: T) {
  return {
    ...movement,
    filled_quantity_change: movement.gas_change + movement.unit_change,
    empty_quantity_change: movement.bottle_change - movement.gas_change,
  };
}
