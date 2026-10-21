import BastionSpikeCore
import Foundation

// GH-86 (F0): túnel nativo a Azure Bastion con auth de `az login`.
exit(await SpikeRunner.main(arguments: Array(CommandLine.arguments.dropFirst())))
