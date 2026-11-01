//
//  SymmetricKey+Extensions.swift
//  NearbyShare
//
//  Created by Grishka on 06.08.2025.
//

import Foundation
import CryptoKit

extension SymmetricKey{
	func data() -> Data{
		return withUnsafeBytes({
			guard let base=$0.baseAddress else {return Data()}
			return Data(bytes: base, count: $0.count)
		})
	}
}
