import SwiftUI

/// Renders a provider logo: SF Symbol for Apple/Microsoft, styled "G" for Google.
struct ServiceLogo: View {
    let iconSystemName: String?
    let letter: String?
    let color: Color
    var size: CGFloat = 12

    var body: some View {
        if let iconSystemName {
            Image(systemName: iconSystemName)
                .font(.system(size: size * scaleFactor))
                .foregroundStyle(color)
        } else if let letter {
            Text(letter)
                .font(.system(size: size * scaleFactor, weight: .bold, design: .rounded))
                .foregroundStyle(color)
        }
    }

    /// Apple logo and Google "G" are visually smaller than the MS grid, so scale them up.
    private var scaleFactor: CGFloat {
        if iconSystemName == "square.grid.2x2.fill" {
            1.0
        } else {
            1.2
        }
    }
}

extension ServiceLogo {
    init(service: ServiceType, size: CGFloat = 12) {
        self.iconSystemName = service.iconSystemName
        self.letter = service.providerLogoLetter
        self.color = service.color
        self.size = size
    }

    init(provider: ServiceProvider, size: CGFloat = 12) {
        self.iconSystemName = provider.iconSystemName
        self.letter = provider.providerLogoLetter
        self.color = provider.taskServiceType.color
        self.size = size
    }
}
